;;; mczy.el --- Emacs input method for mczy-engine -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Shoushan Chiang

;; Author: Shoushan Chiang <turtalk@tuta.io>
;; Version: 0.3
;; Package-Requires: ((emacs "28.1"))
;; Keywords: i18n, input-method, chinese, bopomofo
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; mczy is a real Emacs input method (not a minor mode): activate with
;; `C-\' / `M-x set-input-method RET chinese-mczy'.  It mirrors the
;; built-in `quail' shape -- `register-input-method' plus a buffer-local
;; `input-method-function'; the first key opens a composition session, a
;; composition-time keymap (active only during the session, via
;; `overriding-terminal-local-map', so it does not fight org/evil) drives
;; the following keys, and preedit/candidates render in an overlay near the
;; cursor.  Translation itself is outsourced to mczy-engine over
;; sexp-over-stdio.
;;
;; Committed text is returned to the command loop as events; a key the
;; engine does not absorb (`(done nil)') falls through to Emacs.  In
;; bopomofo mode a single space (empty buffer) outputs a space and switches
;; to English; in English mode two consecutive spaces switch back.  Either
;; direction can be turned off with `mczy-space-toggle', leaving the
;; explicit `mczy-toggle-english' as the way to switch.

;;; Code:

(require 'cl-lib)

(defgroup mczy nil
  "mczy input method settings."
  :group 'input-method
  :prefix "mczy-")

(defconst mczy--base-dir
  (let ((file (or load-file-name buffer-file-name)))
    (if file
        (file-name-directory (file-chase-links file))
      default-directory))
  "Directory containing mczy.el (symlinks resolved).")

(defcustom mczy-engine-path
  (expand-file-name "engine/build/mczy-engine" mczy--base-dir)
  "Path to the mczy-engine executable."
  :type 'file
  :group 'mczy)

(defcustom mczy-data-path
  (expand-file-name "engine/vendor/fcitx5-mcbopomofo/data/data.txt"
                    mczy--base-dir)
  "Path to McBopomofo data.txt."
  :type 'file
  :group 'mczy)

(defcustom mczy-response-timeout 2.0
  "Seconds to wait for mczy-engine to finish one command turn."
  :type 'number
  :group 'mczy)

(defcustom mczy-candidate-keys "1234567890"
  "Keys used to select candidates in choosing state.
The first character selects candidate 0, the second selects candidate 1,
and so on.  For example, set this to \"qweruiop\" to use q/w/e/r/u/i/o/p
as candidate keys."
  :type 'string
  :group 'mczy)

(defcustom mczy-candidate-layout 'horizontal
  "Layout for the candidate selection overlay.
`horizontal' places all candidates on one line separated by spaces.
`vertical' places one candidate per line."
  :type '(choice (const :tag "Horizontal" horizontal)
                 (const :tag "Vertical" vertical))
  :group 'mczy)

(defcustom mczy-hide-cursor-while-composing t
  "Whether to hide the original cursor during composition."
  :type 'boolean
  :group 'mczy)

(defcustom mczy-toggle-candidate-layout-key (kbd "<f8>")
  "Key that toggles the candidate overlay between horizontal and vertical.
The key is active during composition, including while the candidate box is
visible.  It must be a single key event, such as `F8' or `M-l'.  Set it to nil
to disable the composition-time binding; the command
`mczy-toggle-candidate-layout' remains available via `M-x'."
  :type '(choice (const :tag "No binding" nil)
                 (key-sequence :tag "Key"))
  :group 'mczy)

(defcustom mczy-user-phrases-path
  (locate-user-emacs-file "mczy-user-phrases.txt")
  "File where phrases added via marking (Shift+Left/Right then Enter) are kept.
Passed to mczy-engine, which creates it if missing, appends new phrases,
and reloads it so an added phrase is immediately selectable.  Kept out of
the repository (under the user's Emacs directory) by default."
  :type 'file
  :group 'mczy)

(defcustom mczy-space-toggle 'both
  "Which space-triggered Chinese/English switches are enabled.

The two directions are deliberately asymmetric, so they can be enabled
separately:

  bopomofo -> English   a single space in an *empty* composition emits one
                        space and leaves the engine (never fires mid-word,
                        so tone-1 spaces are unaffected)
  English -> bopomofo   two consecutive spaces switch back, collapsing to
                        a single space

Value is one of:

  `both'        both directions (default)
  `to-english'  only bopomofo -> English
  `to-chinese'  only English -> bopomofo
  nil           neither; switch explicitly instead

With a direction disabled, space keeps its plain meaning there: in bopomofo
mode it goes to the engine, in English mode it self-inserts.  The explicit
commands `mczy-toggle-english', `mczy-set-english' and `mczy-set-chinese'
work regardless of this setting; bind one of them if you turn the automatic
switching off."
  :type '(choice (const :tag "Both directions" both)
                 (const :tag "Only bopomofo -> English" to-english)
                 (const :tag "Only English -> bopomofo" to-chinese)
                 (const :tag "Disabled" nil))
  :group 'mczy)

(defcustom mczy-title "麥"
  "Base name shown in the mode line.
The sub-mode indicator is appended to it, giving 麥注 / 麥Aa."
  :type 'string
  :group 'mczy)

(defcustom mczy-chinese-indicator "注"
  "Suffix appended to `mczy-title' while in bopomofo (Chinese) mode."
  :type 'string
  :group 'mczy)

(defcustom mczy-english-indicator "Aa"
  "Suffix appended to `mczy-title' while in English self-insert mode."
  :type 'string
  :group 'mczy)

(defun mczy--resolve-path (path)
  "Return PATH as an absolute file name rooted at `mczy--base-dir'.
This keeps relative custom values such as \"engine/build/mczy-engine\"
working even when `default-directory' is some unrelated editing buffer."
  (expand-file-name path mczy--base-dir))

(defface mczy-cursor-face
  '((t (:inherit cursor)))
  "Face used for the composition cursor marker."
  :group 'mczy)

(defface mczy-candidate-key-face
  '((t (:inherit font-lock-keyword-face :weight bold)))
  "Face used for candidate number keys."
  :group 'mczy)

(defface mczy-marked-face
  '((t (:inherit region)))
  "Face used for the marked span while selecting a phrase to add."
  :group 'mczy)

(defface mczy-overlay-face
  '((((class color) (background light))
     (:background "#f0f0ff" :foreground "black"
      :box (:line-width 1 :color "#aaaacc")))
    (((class color) (background dark))
     (:background "#2a2a4a" :foreground "white"
      :box (:line-width 1 :color "#7777aa")))
    (t (:inverse-video t)))
  "Face for the inline candidate selection overlay."
  :group 'mczy)

(defvar-local mczy--process nil
  "Buffer-local mczy-engine process.")

(defvar-local mczy--state 'empty
  "Current engine state.")

(defvar-local mczy--preedit ""
  "Current composing text.")

(defvar-local mczy--cursor 0
  "Current codepoint cursor in `mczy--preedit'.")

(defvar-local mczy--candidates nil
  "Current candidate list (the full list from the engine).")

(defvar-local mczy--page 0
  "Current 0-based candidate page within `mczy--candidates'.
The engine sends every homophone at once; paging is a display concern, so
this slices the list into pages of `mczy-candidate-keys' length.")

(defvar-local mczy--marking nil
  "Current marking payload, if any.")

(defvar-local mczy--english-mode nil
  "Non-nil when the double-space toggle has switched to English self-insert.
Distinct from leaving the input method with `C-\\': keys pass through as
self-insert while the engine stays available, until two spaces toggle back.")

(defvar-local mczy--space-run 0
  "Count of consecutive spaces, for the double-space Chinese/English toggle.
Any non-space key resets it to 0; reaching 2 toggles.")

(defvar mczy--editing-buffer nil
  "Editing buffer for the active composition session.")

(defvar mczy--overlay nil
  "Overlay showing candidates near the cursor during selection.")

(defvar mczy--translating nil
  "Non-nil while a composition session is running.
Dynamically bound by `mczy--translate'; command handlers clear it to
end the session.")

(defvar mczy--result-events nil
  "Committed events to return from the current composition session.
Dynamically bound by `mczy--translate'.")

(defvar mczy-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<f9>") #'mczy-toggle-english)
    map)
  "Keymap active in buffers where mczy is the current input method.
Gated on `mczy--active' via `minor-mode-map-alist', so it is live only
where mczy is activated and never fights the composition-time
`overriding-terminal-local-map'.")

(defvar-local mczy--active nil
  "Non-nil in buffers where mczy is active; gates `mczy-mode-map'.")

(add-to-list 'minor-mode-map-alist (cons 'mczy--active mczy-mode-map))

(defun mczy-set-candidate-keys (keys)
  "Set `mczy-candidate-keys' to KEYS and refresh the display."
  (interactive "sCandidate keys: ")
  (unless (and (stringp keys) (> (length keys) 0))
    (error "Candidate keys must be a non-empty string"))
  (setq mczy-candidate-keys keys)
  (when (eq mczy--state 'choosing)
    (mczy--render)))

(defun mczy-toggle-candidate-layout ()
  "Toggle the candidate overlay between horizontal and vertical layouts."
  (interactive)
  (setq mczy-candidate-layout
        (if (eq mczy-candidate-layout 'horizontal)
            'vertical
          'horizontal)
        mczy--space-run 0)
  (when (eq mczy--state 'choosing)
    (mczy--render))
  (message "mczy: candidate layout %s"
           (if (eq mczy-candidate-layout 'horizontal)
               "horizontal"
             "vertical")))

;;; Stream parser

(defun mczy--skip-blanks (text pos)
  "Return first non-blank position in TEXT at or after POS."
  (or (string-match "[^ \t\n\r]" text pos) (length text)))

(defun mczy--read-forms (text)
  "Read complete sexps from TEXT.
Return (FORMS . REST), where REST is an incomplete tail to keep for the
next process chunk."
  (let ((pos 0)
        (forms nil)
        (rest nil)
        (done nil)
        (len (length text)))
    (while (not done)
      (setq pos (mczy--skip-blanks text pos))
      (if (>= pos len)
          (setq rest ""
                done t)
        (let ((form-start pos))
          (condition-case err
              (let* ((read-result (read-from-string text pos))
                     (form (car read-result))
                     (next-pos (cdr read-result)))
                (push form forms)
                (setq pos next-pos))
            (end-of-file
             (setq rest (substring text form-start)
                   done t))
            (error
             (error "Invalid mczy engine output near %S: %s"
                    (substring text form-start (min len (+ form-start 80)))
                    (error-message-string err)))))))
    (cons (nreverse forms) rest)))

;;; Process management

(defun mczy--process-filter (proc chunk)
  "Append CHUNK to PROC's pending stdout."
  (process-put proc 'pending-output
               (concat (or (process-get proc 'pending-output) "") chunk)))

(defun mczy--process-forms (proc)
  "Drain complete sexps currently buffered for PROC."
  (pcase-let ((`(,forms . ,rest)
               (mczy--read-forms
                (or (process-get proc 'pending-output) ""))))
    (process-put proc 'pending-output rest)
    forms))

(defun mczy--reset-state ()
  "Reset buffer-local frontend state."
  (setq mczy--state 'empty
        mczy--preedit ""
        mczy--cursor 0
        mczy--candidates nil
        mczy--page 0
        mczy--marking nil))

(defun mczy--ensure-process ()
  "Return a live mczy-engine process for this buffer."
  (if (process-live-p mczy--process)
      mczy--process
    (mczy--start-process)))

(defun mczy-compile-engine ()
  "Compile mczy-engine, showing progress in a `compilation-mode' buffer.
Runs submodule init, CMake configure, and build in the directory
containing mczy.el.  Requires git, CMake >= 3.16, a C++20 compiler,
and ICU (macOS: brew install cmake icu4c)."
  (interactive)
  (let ((default-directory mczy--base-dir)
        (icu-root (when (eq system-type 'darwin)
                    (ignore-errors
                      (car (process-lines "brew" "--prefix" "icu4c"))))))
    (compile (concat "git submodule update --init"
                     " && cmake -S engine -B engine/build -DCMAKE_BUILD_TYPE=Release"
                     (when icu-root
                       (concat " -DICU_ROOT=" (shell-quote-argument icu-root)))
                     " && cmake --build engine/build -j"))))

(defun mczy--start-process ()
  "Start mczy-engine for the current buffer."
  (interactive)
  (when (process-live-p mczy--process)
    (delete-process mczy--process))
  (let ((engine-path (mczy--resolve-path mczy-engine-path))
        (data-path (mczy--resolve-path mczy-data-path)))
    (unless (file-executable-p engine-path)
      (if (and (file-exists-p (expand-file-name "engine/CMakeLists.txt"
                                                mczy--base-dir))
               (y-or-n-p "mczy-engine 尚未編譯，現在編譯嗎？"))
          (progn
            (mczy-compile-engine)
            (user-error "mczy-engine 編譯中，完成後再 toggle-input-method 一次"))
        (error "mczy-engine is not executable: %s" engine-path)))
    (unless (file-readable-p data-path)
      (error "McBopomofo data file is not readable: %s" data-path))
    (let ((proc (make-process
                 :name "mczy-engine"
                 :buffer nil
                 :command (list engine-path data-path
                                (mczy--resolve-path mczy-user-phrases-path))
                 :connection-type 'pipe
                 :coding 'utf-8-unix
                 :noquery t
                 :filter #'mczy--process-filter)))
      (set-process-query-on-exit-flag proc nil)
      (process-put proc 'pending-output "")
      (setq mczy--process proc)
      (mczy--reset-state)
      proc)))

(defun mczy--stop-process ()
  "Stop this buffer's mczy-engine process."
  (interactive)
  (when (process-live-p mczy--process)
    (delete-process mczy--process))
  (setq mczy--process nil)
  (mczy--overlay-hide))

(defun mczy--send-command (command)
  "Send COMMAND to mczy-engine and return (STATES . DONE-VALUE)."
  (let ((proc (mczy--ensure-process))
        (states nil)
        (done-seen nil)
        (done-value nil))
    (process-put proc 'pending-output "")
    (process-send-string proc (concat (prin1-to-string command) "\n"))
    (let ((deadline (+ (float-time) mczy-response-timeout)))
      (while (not done-seen)
        (unless (process-live-p proc)
          (error "mczy-engine exited before replying to %S" command))
        ;; Blocking round-trip inside the translate loop is safe
        ;; here -- plain synchronous elisp in one command-loop turn, like
        ;; quail's read loop minus the subprocess.  The minibuffer/isearch
        ;; reentrancy case is M3b.
        ;; Wait for the remaining budget in one call; accept-process-output
        ;; returns as soon as output arrives, so this is not a 2s stall.
        (accept-process-output proc (max 0.01 (- deadline (float-time))))
        (dolist (form (mczy--process-forms proc))
          (if (and (consp form) (eq (car form) 'done))
              (setq done-seen t
                    done-value (cadr form))
            (push form states)))
        (when (and (not done-seen)
                   (> (float-time) deadline))
          (error "Timed out waiting for mczy-engine after %S" command))))
    (cons (nreverse states) done-value)))

;;; State handling

(defun mczy--state-value (state key &optional default)
  "Return KEY's scalar value from STATE."
  (let ((cell (assq key (cdr state))))
    (if cell
        (cadr cell)
      default)))

(defun mczy--state-list (state key)
  "Return KEY's variadic list value from STATE."
  (cdr (assq key (cdr state))))

(defun mczy--set-preedit-state (kind state)
  "Apply preedit KIND using engine STATE."
  (setq mczy--state kind
        mczy--preedit (or (mczy--state-value state 'buffer) "")
        mczy--cursor (or (mczy--state-value state 'cursor) 0)
        mczy--candidates nil
        mczy--marking nil))

(defun mczy--apply-state (state)
  "Apply one engine STATE.
Return committed text for commit states, otherwise nil."
  (pcase (car-safe state)
    ((or 'inputting 'state)
     (mczy--set-preedit-state 'inputting state)
     nil)
    ('choosing
     (mczy--set-preedit-state 'choosing state)
     (setq mczy--candidates (mczy--state-list state 'candidates)
           ;; a fresh choosing state starts at the first page; page navigation
           ;; does not go through the engine, so it does not reset this.
           mczy--page 0)
     nil)
    ('marking
     (setq mczy--state 'marking
           mczy--marking (cdr state)
           mczy--preedit ""
           mczy--cursor 0
           mczy--candidates nil)
     nil)
    ('commit
     (setq mczy--state 'committing)
     (cadr state))
    ('empty
     (mczy--reset-state)
     nil)
    ('error
     (message "mczy-engine returned (error)")
     nil)
    (_
     (message "Unknown mczy state: %S" state)
     nil)))

(defun mczy--apply-states (states)
  "Apply STATES, render the display, and return committed strings."
  (let (commits)
    (dolist (state states)
      (when-let ((commit (mczy--apply-state state)))
        (push commit commits)))
    (when (eq mczy--state 'committing)
      (mczy--reset-state))
    (mczy--render)
    (nreverse commits)))

;;; Display

(defun mczy--clamped-cursor (text cursor)
  "Clamp CURSOR to a valid character index in TEXT."
  (max 0 (min (or cursor 0) (length text))))

(defun mczy--page-count ()
  "Number of candidate pages for the current list and key set."
  (max 1 (ceiling (length mczy--candidates)
                  (length mczy-candidate-keys))))

(defun mczy--clamped-page ()
  "Current page index, clamped to the valid range."
  (min (max 0 mczy--page) (1- (mczy--page-count))))

(defun mczy--render-candidates (candidates page)
  "Render PAGE of CANDIDATES with `mczy-candidate-keys'.
The engine sends all homophones at once; this shows one page and a
`[page/total]' indicator.  Navigate pages with PageDown / PageUp.
PAGE is passed in (not read from a buffer-local) because rendering runs
in the display buffer, where the buffer-local state does not live."
  (let* ((size (length mczy-candidate-keys))
         (total (length candidates))
         (pages (max 1 (ceiling total size)))
         (page (min (max 0 page) (1- pages))))
    (cl-loop for cand in (nthcdr (* page size) candidates)
             for key across mczy-candidate-keys
             do (insert (propertize (char-to-string key)
                                    'face 'mczy-candidate-key-face)
                        ": " cand
                        (if (eq mczy-candidate-layout 'vertical) "\n" "  ")))
    (when (> pages 1)
      (insert (propertize (format " [%d/%d]" (1+ page) pages)
                          'face 'shadow)))))

(defun mczy--format-preedit-overlay (text cursor)
  "Return a propertized string showing TEXT with a cursor marker at CURSOR."
  (let* ((cursor (mczy--clamped-cursor text cursor))
         (face 'mczy-overlay-face))
    (concat
     (propertize (concat " " (substring text 0 cursor)) 'face face)
     (propertize "|" 'face 'mczy-cursor-face)
     (propertize (concat (substring text cursor) " ") 'face face))))

(defun mczy--marking-field (marking key)
  "Return KEY's value from a MARKING payload alist."
  (cadr (assq key marking)))

(defun mczy--format-marking-overlay (marking)
  "Return overlay after-string for marking state."
  (let* ((head     (or (mczy--marking-field marking 'head) ""))
         (marked   (or (mczy--marking-field marking 'marked) ""))
         (tail     (or (mczy--marking-field marking 'tail) ""))
         (ok       (mczy--marking-field marking 'acceptable))
         (face     'mczy-overlay-face)
         (text-line (concat
                     (propertize (concat " " head) 'face face)
                     (propertize marked 'face '(mczy-marked-face mczy-overlay-face))
                     (propertize (concat tail " ") 'face face)))
         (hint      (if ok "Enter 加入自訂字庫"
                      "(無法加入:需 2–8 字且尚未存在;Shift+←/→ 調整)"))
         (hint-line (propertize (concat " " hint " ")
                                'face (if ok 'success 'shadow))))
    (concat text-line "\n" hint-line)))

(defun mczy--overlay-update (state preedit cursor candidates page marking)
  "Show preedit, candidates, or marking info in an overlay near point."
  (when (buffer-live-p mczy--editing-buffer)
    (with-current-buffer mczy--editing-buffer
      (let ((pos (point)))
        (unless (and (overlayp mczy--overlay)
                     (eq (overlay-buffer mczy--overlay) (current-buffer)))
          (when (overlayp mczy--overlay)
            (delete-overlay mczy--overlay))
          (setq mczy--overlay (make-overlay pos pos nil t nil)))
        (move-overlay mczy--overlay pos pos)
        (let ((after
               (pcase state
                 ('marking
                  (mczy--format-marking-overlay marking))
                 (_
                  (let ((preedit-line (mczy--format-preedit-overlay preedit cursor)))
                    (if (eq state 'choosing)
                        (let* ((cands (with-temp-buffer
                                        (mczy--render-candidates candidates page)
                                        (buffer-string)))
                               (cands (if (eq mczy-candidate-layout 'vertical)
                                          (replace-regexp-in-string "\n" "\n " cands)
                                        cands))
                               (cand-line (propertize (concat " " cands " ")
                                                      'face 'mczy-overlay-face)))
                          (concat preedit-line "\n" cand-line))
                      preedit-line))))))
          (overlay-put mczy--overlay 'after-string after)
          (overlay-put mczy--overlay 'priority 1000))))))

(defun mczy--overlay-hide ()
  "Delete the candidate overlay."
  (when (overlayp mczy--overlay)
    (delete-overlay mczy--overlay)
    (setq mczy--overlay nil)))

(defun mczy--render ()
  "Render current frontend state as an overlay near the cursor."
  (if (memq mczy--state '(inputting choosing marking))
      (mczy--overlay-update mczy--state mczy--preedit mczy--cursor
                              mczy--candidates mczy--page mczy--marking)
    (mczy--overlay-hide)))

;;; Commands (run inside a composition session)

(defun mczy--add-unread-command-events (key &optional reset)
  "Add KEY to `unread-command-events', avoiding a second recording.
Copied from `quail-add-unread-command-events': keys handed back to the
command loop (fall-through and the unconsumed key) are wrapped so they
are not recorded twice in `recent-keys' or a running keyboard macro.
KEY is a character, an event, or a vector of events; with RESET non-nil
`unread-command-events' is cleared first."
  (if reset (setq unread-command-events nil))
  (setq unread-command-events
        (if (characterp key)
            (cons (cons 'no-record key) unread-command-events)
          (append (mapcan (lambda (e) (list (cons 'no-record e)))
                          (append (if (vectorp key) key (vector key)) nil))
                  unread-command-events))))

(defun mczy--key-events (key)
  "Return KEY (a character, event, string, or vector) as a flat event list."
  (cond ((null key) nil)
        ((vectorp key) (append key nil))
        ((stringp key) (append key nil))
        ((listp key) key)
        (t (list key))))

(defun mczy--fall-through (key)
  "End the session, returning KEY's events for Emacs to handle.
Fall-through events MUST be returned from `input-method-function' (which
are processed once, unfiltered), never pushed onto `unread-command-events'
\(which re-enters the input method and loops forever)."
  (setq mczy--result-events
        (append mczy--result-events (mczy--key-events key))
        mczy--translating nil))

(defun mczy--run-command (command fallback-key)
  "Send COMMAND, apply the reply, and steer the composition session.
On commit, queue the committed characters as result events and end the
session.  When the engine reports the key was not absorbed (`done' nil),
hand FALLBACK-KEY back to Emacs and end the session.  When the engine
absorbed the key but composition ended (state empty), just end the
session.  Otherwise keep composing."
  (pcase-let ((`(,states . ,done) (mczy--send-command command)))
    (let ((commits (mczy--apply-states states)))
      (cond
       (commits
        (setq mczy--result-events
              (append mczy--result-events
                      (apply #'append (mapcar #'string-to-list commits)))
              mczy--translating nil))
       ((null done)
        (mczy--fall-through fallback-key))
       ((eq mczy--state 'empty)
        (setq mczy--translating nil))))))

(defun mczy--candidate-key-index (char)
  "Return candidate index selected by CHAR, or nil."
  (cl-position char mczy-candidate-keys :test #'char-equal))

(defun mczy--handle-character ()
  "Send the typed character as a candidate key or `(key \"x\")' command."
  (interactive)
  (setq mczy--space-run 0)
  (let ((char last-command-event))
    (unless (characterp char)
      (error "Not a character event: %S" char))
    ;; While choosing, a candidate key selects the global engine index (page
    ;; offset plus key position) -- unless it points past the last, partial
    ;; page, in which case it is ordinary input like any other key.
    (let ((global (and (eq mczy--state 'choosing)
                       (when-let ((idx (mczy--candidate-key-index char)))
                         (+ (* (length mczy-candidate-keys)
                               (mczy--clamped-page))
                            idx)))))
      (mczy--run-command
       (if (and global (< global (length mczy--candidates)))
           (list 'select global)
         (list 'key (char-to-string char)))
       (this-single-command-raw-keys)))))

(defun mczy--page-move (delta)
  "Move the candidate page by DELTA (wrapping) when choosing.
Return non-nil if it paged; nil otherwise (so callers can fall through)."
  (when (eq mczy--state 'choosing)
    (setq mczy--page (mod (+ (mczy--clamped-page) delta)
                            (mczy--page-count)))
    (mczy--render)
    t))

(defun mczy--page-next ()
  "Show the next candidate page, or fall through when not choosing."
  (interactive)
  (setq mczy--space-run 0)
  (unless (mczy--page-move 1)
    (mczy--fall-through (this-single-command-raw-keys))))

(defun mczy--page-prev ()
  "Show the previous candidate page, or fall through when not choosing."
  (interactive)
  (setq mczy--space-run 0)
  (unless (mczy--page-move -1)
    (mczy--fall-through (this-single-command-raw-keys))))

(defun mczy--page-or-character (delta)
  "Page candidates by DELTA while choosing; otherwise input the key.
Lets j/k page the candidate list without shadowing them as engine input
during composition (when not choosing, they reach `mczy--handle-character'
and become bopomofo like any other letter)."
  (if (mczy--page-move delta)
      (setq mczy--space-run 0)
    (mczy--handle-character)))

(defun mczy--handle-named-key (name)
  "Send NAME as a named `(key NAME)' command."
  (setq mczy--space-run 0)
  (mczy--run-command (list 'key name) (this-single-command-raw-keys)))

(defun mczy--handle-shift-key (name)
  "Send NAME with the shift modifier: `(key NAME shift)'.
Shift+Left/Right extend the marking span; the engine enters its marking
state, and Enter on an acceptable mark adds the phrase to the user dict."
  (setq mczy--space-run 0)
  (mczy--run-command (list 'key name 'shift) (this-single-command-raw-keys)))

(defun mczy--space-toggles-p (direction)
  "Non-nil when `mczy-space-toggle' enables DIRECTION.
DIRECTION is `to-english' or `to-chinese'."
  (memq mczy-space-toggle (list 'both direction)))

(defun mczy--handle-space ()
  "Handle space in Chinese mode.
In a multi-page candidate box, advance one page and wrap after the last page.
From an empty buffer, immediately output a space and switch to English (so the
toggle never interferes with tone-1 spaces mid-word like 窩窩); this branch is
gated on `mczy-space-toggle'.  Other spaces drive the engine as before."
  (interactive)
  (cond
   ((and (eq mczy--state 'choosing)
         (> (mczy--page-count) 1))
    (setq mczy--space-run 0)
    (mczy--page-move 1))
   ((and (eq mczy--state 'empty)
         (mczy--space-toggles-p 'to-english))
        (setq mczy--result-events (append mczy--result-events (list ?\s)))
        (mczy--toggle-from-chinese))
   (t
    (setq mczy--space-run 0)
    (mczy--run-command '(key space) (this-single-command-raw-keys)))))

(defun mczy--set-english-mode (enable)
  "Switch to English self-insert when ENABLE, else back to bopomofo."
  (setq mczy--english-mode enable
        mczy--space-run 0)
  (mczy--update-mode-line-title)
  (message (if enable "mczy: English" "mczy: 中文")))

(defun mczy--toggle-from-chinese ()
  "Single space in an empty buffer: switch to English self-insert."
  (mczy--set-english-mode t)
  (setq mczy--translating nil))

(defun mczy--toggle-to-chinese ()
  "Double-space in English mode: switch back to bopomofo."
  (mczy--set-english-mode nil)
  nil)

(defun mczy-toggle-english ()
  "Toggle bopomofo/English; a one-key alternative to the double space."
  (interactive)
  (mczy--set-english-mode (not mczy--english-mode)))

(defun mczy-set-english (&rest _)
  "Switch to English self-insert mode; no-op unless mczy is active.
Quiet, and accepts (and ignores) arguments, so it can be added directly
as advice on movement commands (avy, worf, ...) that should always land
in English mode."
  (interactive)
  (when mczy--active
    (setq mczy--english-mode t
          mczy--space-run 0)
    (mczy--update-mode-line-title)))

(defun mczy-set-chinese (&rest _)
  "Switch to bopomofo (Chinese) mode; no-op unless mczy is active.
Quiet advice-friendly counterpart of `mczy-set-english'."
  (interactive)
  (when mczy--active
    (setq mczy--english-mode nil
          mczy--space-run 0)
    (mczy--update-mode-line-title)))

(defun mczy--other-command ()
  "End the session and hand the typed key back to Emacs.
Bound to control keys mczy does not use so `read-key-sequence' resolves
them immediately instead of waiting for a prefix completion (e.g. `C-x')."
  (interactive)
  (setq mczy--space-run 0)
  (mczy--fall-through (this-single-command-raw-keys)))

(defun mczy-reset ()
  "Reset mczy composition state."
  (interactive)
  (if (process-live-p mczy--process)
      (progn
        (mczy--apply-states (car (mczy--send-command '(reset))))
        (mczy--render))
    (mczy--reset-state)
    (mczy--render)))

;;; Composition-time keymap (active only while translating)

(defun mczy--make-composition-map ()
  "Build the composition-time keymap used during a session.
A full keymap (not sparse) with every control key bound so an unused one
like `C-x' resolves immediately rather than waiting as a prefix; printable
keys drive the engine, and the named keys below override the defaults."
  (let ((map (make-keymap)))
    ;; Control keys mczy does not claim fall through (and end the session).
    ;; C-b/C-f/TAB/RET/DEL etc. are re-bound to engine keys just below.
    (dotimes (i 32)
      (define-key map (vector i) #'mczy--other-command))
    (dotimes (offset 95)
      (let ((char (+ 32 offset)))
        (unless (= char ?\s)
          (define-key map (string char) #'mczy--handle-character))))
    (define-key map (kbd "SPC") #'mczy--handle-space)
    ;; Named engine keys (C-b/C-f mirror Left/Right, Emacs-style).
    (pcase-dolist (`(,key . ,name)
                   `(("\r" . return) ([return] . return)
                     ("\t" . tab)
                     ([?\C-?] . backspace) ([backspace] . backspace)
                     ([delete] . delete) ([escape] . esc)
                     ("\C-b" . left) ("\C-f" . right)
                     ([left] . left) ([right] . right) ([up] . up)
                     ([down] . down) ([home] . home) ([end] . end)))
      (define-key map key
                  (lambda () (interactive) (mczy--handle-named-key name))))
    ;; Shift+Left/Right (and GUI-only C-S-b/C-S-f mirrors): mark a phrase
    ;; span to add to the user dictionary.
    ;; TTY can't distinguish C-S-f/C-S-b; pick a TTY-reachable
    ;; alternative (e.g. a prefix or M- combo) if that matters.
    (pcase-dolist (`(,key . ,name)
                   `(([S-left] . left) ([S-right] . right)
                     (,(kbd "C-S-b") . left) (,(kbd "C-S-f") . right)))
      (define-key map key
                  (lambda () (interactive) (mczy--handle-shift-key name))))
    ;; Candidate paging (active only while choosing; falls through otherwise).
    (define-key map [next] #'mczy--page-next)
    (define-key map [prior] #'mczy--page-prev)
    (define-key map (kbd "C-n") #'mczy--page-next)
    (define-key map (kbd "C-p") #'mczy--page-prev)
    ;; j/k page down/up while choosing; otherwise they are normal input.
    (define-key map "j" (lambda () (interactive) (mczy--page-or-character 1)))
    (define-key map "k" (lambda () (interactive) (mczy--page-or-character -1)))
    (when mczy-toggle-candidate-layout-key
      (unless (= (length mczy-toggle-candidate-layout-key) 1)
        (error "Mczy layout toggle must be a single key event"))
      (define-key map mczy-toggle-candidate-layout-key
                  #'mczy-toggle-candidate-layout))
    map))

(defvar mczy--composition-map nil
  "Cached composition-time keymap; set to nil to force a rebuild.")

(defvar mczy--composition-map-layout-key nil
  "Layout toggle key used to build `mczy--composition-map'.")

(defun mczy--composition-keymap ()
  "Return the composition-time keymap; rebuild it when its option changes."
  (unless (and mczy--composition-map
               (equal mczy--composition-map-layout-key
                      mczy-toggle-candidate-layout-key))
    (setq mczy--composition-map (mczy--make-composition-map)
          mczy--composition-map-layout-key
          (copy-sequence mczy-toggle-candidate-layout-key)))
  mczy--composition-map)

;;; Input method entry

(defun mczy--translate (first-key)
  "Run one composition session starting with FIRST-KEY.
Return a list of events for the command loop (committed characters, or
empty when the session ends with a fall-through or a cleared buffer).
Mirrors `quail-start-translation': `input-method-function' is bound to
nil and the composition keymap drives `read-key-sequence' until a
handler ends the session or an unbound key sequence falls through."
  (let ((mczy--translating t)
        (mczy--result-events nil)
        (mczy--editing-buffer (current-buffer))
        (mczy--overlay nil)
        (input-method-function nil)
        (overriding-terminal-local-map (mczy--composition-keymap))
        (echo-keystrokes 0)
        (help-char nil)
        (cursor-type-was-local (local-variable-p 'cursor-type))
        (previous-cursor-type cursor-type)
        last-command-event last-command this-command)
    (mczy--reset-state)
    (mczy--ensure-process)
    (mczy--render)
    (when mczy-hide-cursor-while-composing
      (setq-local cursor-type nil))
    (unwind-protect
        (progn
          (mczy--add-unread-command-events first-key)
          (while mczy--translating
            (mczy--render)
            (let* ((keyseq (read-key-sequence nil nil nil t))
                   (cmd (lookup-key (mczy--composition-keymap) keyseq)))
              (if (commandp cmd)
                  (progn
                    (setq last-command-event (aref keyseq (1- (length keyseq)))
                          last-command this-command
                          this-command cmd)
                    (call-interactively cmd))
                ;; Unbound in the composition keymap (function key, mouse,
                ;; multi-key): hand it back to Emacs and end the session.
                (mczy--fall-through keyseq)))))
      ;; A non-local exit (C-g) can leave the engine half-composed, which
      ;; would poison the next session; reset it.  M3b owns full C-g UX.
      (when (memq mczy--state '(inputting choosing marking))
        (ignore-errors (mczy--send-command '(reset))))
      (mczy--reset-state)
      (mczy--overlay-hide)
      (when mczy-hide-cursor-while-composing
        (if cursor-type-was-local
            (setq-local cursor-type previous-cursor-type)
          (kill-local-variable 'cursor-type))))
    mczy--result-events))

(defun mczy--input-method (key)
  "`input-method-function' entry point for KEY.
Fall through verbatim in read-only or overriding-map contexts (matching
`quail-input-method').  In English self-insert mode pass keys through,
counting consecutive spaces to toggle back when `mczy-space-toggle' allows
it.  Otherwise start a composition session."
  (cond
   ((or (and (or buffer-read-only
                 (and (get-char-property (point) 'read-only)
                      (get-char-property (point) 'front-sticky)))
             (not (or inhibit-read-only
                      (get-char-property (point) 'inhibit-read-only))))
        (and overriding-terminal-local-map
             (or (not (eq (cadr overriding-terminal-local-map)
                          universal-argument-map))
                 (lookup-key overriding-terminal-local-map (vector key))))
        overriding-local-map)
    (list key))
   (mczy--english-mode
    (if (and (eq key ?\s)
             (mczy--space-toggles-p 'to-chinese))
        (progn
          (cl-incf mczy--space-run)
          (if (>= mczy--space-run 2)
              (mczy--toggle-to-chinese)
            (list key)))
      (setq mczy--space-run 0)
      (list key)))
   (t
    (mczy--translate key))))

(defun mczy--exit-from-minibuffer ()
  "Deactivate mczy when leaving a minibuffer it was activated in.
Mirrors `quail-exit-from-minibuffer': a minibuffer entered with
`inherit-input-method' activates mczy in its own buffer (a second
engine); without this its engine process would leak on exit."
  (deactivate-input-method)
  (when (<= (minibuffer-depth) 1)
    (remove-hook 'minibuffer-exit-hook #'mczy--exit-from-minibuffer)))

(defun mczy--mode-line-title ()
  "Return the mode-line title for the current sub-mode."
  (concat mczy-title
          (if mczy--english-mode
              mczy-english-indicator
            mczy-chinese-indicator)))

(defun mczy--update-mode-line-title ()
  "Refresh `current-input-method-title' from the current sub-mode.
`activate-input-method' only falls back to the registered title when the
activation function leaves `current-input-method-title' nil, so setting it
here -- at activation and on each Chinese/English toggle -- makes the
dynamic title stick."
  (setq current-input-method-title (mczy--mode-line-title))
  (force-mode-line-update))

;;;###autoload
(defun mczy-activate (&optional arg)
  "Activate the mczy input method.
With negative ARG, deactivate it.  Sets a buffer-local
`input-method-function' so `C-\\' / `toggle-input-method' drive mczy."
  (if (and arg (< (prefix-numeric-value arg) 0))
      (mczy-deactivate)
    (setq deactivate-current-input-method-function #'mczy-deactivate)
    (mczy--start-process)
    (setq mczy--english-mode nil
          mczy--space-run 0)
    (setq-local input-method-function #'mczy--input-method)
    (setq mczy--active t)
    (mczy--update-mode-line-title)
    ;; In a minibuffer (e.g. entered with inherit-input-method, which is also
    ;; how isearch feeds the input method), clean up on exit.
    (when (eq (selected-window) (minibuffer-window))
      (add-hook 'minibuffer-exit-hook #'mczy--exit-from-minibuffer))))

(defun mczy-deactivate ()
  "Deactivate the mczy input method in this buffer."
  (mczy--stop-process)
  (setq mczy--active nil)
  (kill-local-variable 'input-method-function))

;;;###autoload
(register-input-method
 "chinese-mczy" "Chinese-BIG5" #'mczy-activate mczy-title
 "mczy: McBopomofo Chinese input via a subprocess engine.")

(provide 'mczy)

;;; mczy.el ends here
