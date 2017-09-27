;;; flymake-ui.el --- A universal on-the-fly syntax checker  -*- lexical-binding: t; -*-

;; Copyright (C) 2003-2017 Free Software Foundation, Inc.

;; Author:  Pavel Kobyakov <pk_at_work@yahoo.com>
;; Maintainer: Leo Liu <sdl.web@gmail.com>
;; Version: 0.3
;; Keywords: c languages tools

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Flymake is a minor Emacs mode performing on-the-fly syntax checks.xo
;;
;; This file contains the UI for displaying and interacting with the
;; results of such checks, as well as entry points for backends to
;; hook on to. Backends are sources of diagnostic info.
;;
;;; Code:

(require 'cl-lib)
(require 'thingatpt) ; end-of-thing
(require 'warnings) ; warning-numeric-level

(defgroup flymake nil
  "Universal on-the-fly syntax checker."
  :version "23.1"
  :link '(custom-manual "(flymake) Top")
  :group 'tools)

(defcustom flymake-error-bitmap '(exclamation-mark error)
  "Bitmap (a symbol) used in the fringe for indicating errors.
The value may also be a list of two elements where the second
element specifies the face for the bitmap.  For possible bitmap
symbols, see `fringe-bitmaps'.  See also `flymake-warning-bitmap'.

The option `flymake-fringe-indicator-position' controls how and where
this is used."
  :group 'flymake
  :version "24.3"
  :type '(choice (symbol :tag "Bitmap")
                 (list :tag "Bitmap and face"
                       (symbol :tag "Bitmap")
                       (face :tag "Face"))))

(defcustom flymake-warning-bitmap 'question-mark
  "Bitmap (a symbol) used in the fringe for indicating warnings.
The value may also be a list of two elements where the second
element specifies the face for the bitmap.  For possible bitmap
symbols, see `fringe-bitmaps'.  See also `flymake-error-bitmap'.

The option `flymake-fringe-indicator-position' controls how and where
this is used."
  :group 'flymake
  :version "24.3"
  :type '(choice (symbol :tag "Bitmap")
                 (list :tag "Bitmap and face"
                       (symbol :tag "Bitmap")
                       (face :tag "Face"))))

(defcustom flymake-fringe-indicator-position 'left-fringe
  "The position to put flymake fringe indicator.
The value can be nil (do not use indicators), `left-fringe' or `right-fringe'.
See `flymake-error-bitmap' and `flymake-warning-bitmap'."
  :group 'flymake
  :version "24.3"
  :type '(choice (const left-fringe)
		 (const right-fringe)
		 (const :tag "No fringe indicators" nil)))

(defcustom flymake-start-syntax-check-on-newline t
  "Start syntax check if newline char was added/removed from the buffer."
  :group 'flymake
  :type 'boolean)

(defcustom flymake-no-changes-timeout 0.5
  "Time to wait after last change before starting compilation."
  :group 'flymake
  :type 'number)

(defcustom flymake-gui-warnings-enabled t
  "Enables/disables GUI warnings."
  :group 'flymake
  :type 'boolean)
(make-obsolete-variable 'flymake-gui-warnings-enabled
			"it no longer has any effect." "26.1")

(defcustom flymake-start-syntax-check-on-find-file t
  "Start syntax check on find file."
  :group 'flymake
  :type 'boolean)

(defcustom flymake-log-level -1
  "Logging level, only messages with level lower or equal will be logged.
-1 = NONE, 0 = ERROR, 1 = WARNING, 2 = INFO, 3 = DEBUG"
  :group 'flymake
  :type 'integer)

(defcustom flymake-backends '()
  "Ordered list of backends providing syntax check information for a buffer.
Value is an alist of conses (PREDICATE . CHECKER). Both PREDICATE
and CHECKER are functions called without arguments and within the
the buffer in which `flymake-mode' was enabled. PREDICATE is
expected to (quickly) return t or nil if the buffer can be
syntax-checked by CHECKER, in which case it can then perform more
morose operations, possibly asynchronously. After it's done,
CHECKER must invoke `flymake-report' to display the results of
the syntax check." :group 'flymake :type 'alist)

(defvar-local flymake-timer nil
  "Timer for starting syntax check.")

(defvar-local flymake-last-change-time nil
  "Time of last buffer change.")

(defvar-local flymake-check-start-time nil
  "Time at which syntax check was started.")

(defvar-local flymake-check-was-interrupted nil
  "Non-nil if syntax check was killed by `flymake-compile'.")

(defun flymake-log (level text &rest args)
  "Log a message at level LEVEL.
If LEVEL is higher than `flymake-log-level', the message is
ignored.  Otherwise, it is printed using `message'.
TEXT is a format control string, and the remaining arguments ARGS
are the string substitutions (see the function `format')."
  (if (<= level flymake-log-level)
      (let* ((msg (apply #'format-message text args)))
	(message "%s" msg))))

(cl-defstruct (flymake--diag
               (:constructor flymake--diag-make))
  buffer beg end type text)

(defun flymake-make-diagnostic (buffer
                                beg
                                end
                                type
                                text)
  "Mark BUFFER's region from BEG to END with a flymake diagnostic.
TYPE is a key to `flymake-diagnostic-types-alist' and TEXT is a
description of the problem detected in this region."
  (flymake--diag-make :buffer buffer :beg beg :end end :type type :text text))

(defun flymake-ler-make-ler (file line type text &optional full-file)
  (let* ((file (or full-file file))
         (buf (find-buffer-visiting file)))
    (unless buf (error "No buffer visiting %s" file))
    (pcase-let* ((`(,beg . ,end)
                  (with-current-buffer buf
                    (flymake-diag-region line nil))))
      (flymake-make-diagnostic buf beg end type text))))

(make-obsolete 'flymake-ler-make-ler 'flymake-make-diagnostic "26.1")

(cl-defun flymake--overlays (&key beg end filter compare key)
  "Get flymake-related overlays.
If BEG is non-nil and END is nil, consider only `overlays-at'
BEG. Otherwise consider `overlays-in' the region comprised by BEG
and END, defaulting to the whole buffer.  Remove all that do not
verify FILTER, sort them by COMPARE (using KEY)."
  (cl-remove-if-not
   (lambda (ov)
     (and (overlay-get ov 'flymake-overlay)
          (or (not filter)
              (cond ((functionp filter) (funcall filter ov))
                    ((symbolp filter) (overlay-get ov filter))))))
   (save-restriction
     (widen)
     (let ((ovs (if (and beg (null end))
                    (overlays-at beg t)
                  (overlays-in (or beg (point-min))
                               (or end (point-max))))))
       (if compare
           (cl-sort ovs compare :key (or key
                                         #'identity))
         ovs)))))

(defun flymake-delete-own-overlays ()
  "Delete all flymake overlays in BUFFER."
  (mapc #'delete-overlay (flymake--overlays)))

(defface flymake-error
  '((((supports :underline (:style wave)))
     :underline (:style wave :color "Red1"))
    (t
     :inherit error))
  "Face used for marking error regions."
  :version "24.4"
  :group 'flymake)

(defface flymake-warning
  '((((supports :underline (:style wave)))
     :underline (:style wave :color "deep sky blue"))
    (t
     :inherit warning))
  "Face used for marking warning regions."
  :version "24.4"
  :group 'flymake)

(defface flymake-note
  '((((supports :underline (:style wave)))
     :underline (:style wave :color "yellow green"))
    (t
     :inherit warning))
  "Face used for marking note regions."
  :version "26.1"
  :group 'flymake)

(define-obsolete-face-alias 'flymake-warnline 'flymake-warning "26.1")
(define-obsolete-face-alias 'flymake-errline 'flymake-error "26.1")

(defun flymake-diag-region (line col)
  "Compute region (BEG . END) corresponding to LINE and COL.
Or nil if the region is invalid."
  (condition-case-unless-debug _err
      (let ((line (min (max line 1)
                       (line-number-at-pos (point-max) 'absolute))))
        (save-excursion
          (goto-char (point-min))
          (forward-line (1- line))
          (cl-flet ((fallback-bol
                     () (progn (back-to-indentation) (point)))
                    (fallback-eol
                     (beg)
                     (progn
                       (end-of-line)
                       (skip-chars-backward " \t\f\t\n" beg)
                       (if (eq (point) beg)
                           (line-beginning-position 2)
                         (point)))))
            (if col
                (let* ((beg (progn (forward-char (1- col)) (point)))
                       (sexp-end (ignore-errors (end-of-thing 'sexp)))
                       (end (or sexp-end
                                (fallback-eol beg))))
                  (cons (if sexp-end beg (fallback-bol))
                        end))
              (let* ((beg (fallback-bol))
                     (end (fallback-eol beg)))
                (cons beg end))))))
    (error (flymake-log 4 "Invalid region for diagnostic %s")
           nil)))

(defvar flymake-diagnostic-types-alist
  `((:error
     . ((category . flymake-error)))
    (:warning
     . ((category . flymake-warning)))
    (:note
     . ((category . flymake-note))))
  "Alist ((KEY . PROPS)*) of properties of flymake error types.
KEY can be anything passed as `:type' to `flymake-diag-make'.

PROPS is an alist of properties that are applied, in order, to
the overlays representing diagnostics. Every property pertaining
to overlays, including `category', can be used (see Info
Node `(elisp)Overlay Properties'). Some additional properties
with flymake-specific meaning can also be used.

* `bitmap' is a bitmap displayed in the fringe according to
  `flymake-fringe-indicator-position'

* `severity' is a non-negative integer specifying the
  diagnostic's severity. The higher, the more serious. If
  `priority' is not specified, `severity' is used to set it and
  help sort overlapping overlays.")

(put 'flymake-error 'face 'flymake-error)
(put 'flymake-error 'bitmap flymake-error-bitmap)
(put 'flymake-error 'severity (warning-numeric-level :error))

(put 'flymake-warning 'face 'flymake-warning)
(put 'flymake-warning 'bitmap flymake-warning-bitmap)
(put 'flymake-warning 'severity (warning-numeric-level :warning))

(put 'flymake-note 'face 'flymake-note)
(put 'flymake-note 'bitmap flymake-warning-bitmap)
(put 'flymake-note 'severity (warning-numeric-level :debug))

(defun flymake-type-alist (diagnostic-type)
  "Look up DIAGNOSTIC-TYPE in `flymake-diagnostic-types-alist'."
  (assoc-default diagnostic-type
                 flymake-diagnostic-types-alist))

(defun flymake--diag-errorp (diag)
  "Tell if DIAG is a flymake error or something else"
  ;; FIXME repeats some logic in ‘flymake--highlight-line’
  (if-let* ((alist (flymake-type-alist (flymake--diag-type diag)))
            (sev (or (assoc-default 'severity alist)
                     (get (assoc-default 'category alist)
                          'severity))))
      (>= sev (warning-numeric-level :error))
    t))

(defun flymake--fringe-overlay-spec (bitmap)
  (and flymake-fringe-indicator-position
       bitmap
       (propertize "!" 'display
                   (cons flymake-fringe-indicator-position
                         (if (listp bitmap)
                             bitmap
                           (list bitmap))))))

(defun flymake--highlight-line (diagnostic)
  "Highlight buffer with info in DIAGNOSTIC."
  (when-let* ((ov (make-overlay
                   (flymake--diag-beg diagnostic)
                   (flymake--diag-end diagnostic))))
    ;; First copy over to ov every property in the relevant alist.
    ;;
    (cl-loop for (k . v) in
             (flymake-type-alist (flymake--diag-type diagnostic))
             do (overlay-put ov k v))
    ;; Now ensure some defaults are set
    ;;
    (cl-flet ((default-maybe
                (prop value)
                (unless (overlay-get ov prop)
                  (overlay-put ov prop value))))
      (default-maybe 'bitmap flymake-error-bitmap)
      (default-maybe 'before-string
        (flymake--fringe-overlay-spec
         (overlay-get ov 'bitmap)))
      (default-maybe 'help-echo
        (lambda (_window _ov pos)
          (mapconcat
           (lambda (ov)
             (let ((diag (overlay-get ov 'flymake--diagnostic)))
               (flymake--diag-text diag)))
           (flymake--overlays :beg pos)
           "\n")))
      (default-maybe 'severity (warning-numeric-level :error))
      (default-maybe 'priority (+ 100 (overlay-get ov 'severity))))
    ;; Some properties can't be overriden
    ;;
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'flymake-overlay t)
    (overlay-put ov 'flymake--diagnostic diagnostic)))


(defvar-local flymake-is-running nil
  "If t, flymake syntax check process is running for the current buffer.")

(defun flymake-on-timer-event (buffer)
  "Start a syntax check for buffer BUFFER if necessary."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and flymake-mode
                 (not flymake-is-running)
		 flymake-last-change-time
		 (> (- (float-time) flymake-last-change-time)
                    flymake-no-changes-timeout))

	(setq flymake-last-change-time nil)
	(flymake-log 3 "starting syntax check as more than 1 second passed since last change")
	(flymake--start-syntax-check)))))

(define-obsolete-function-alias 'flymake-display-err-menu-for-current-line
  'flymake-popup-current-error-menu "24.4")

(defun flymake-popup-current-error-menu (&optional event)
  "Pop up a menu with errors/warnings for current line."
  (interactive (list last-nonmenu-event))
  (let* ((diag-overlays (or
                         (flymake--overlays :filter 'flymake--diagnostic
                                            :beg (line-beginning-position)
                                            :end (line-end-position))
                         (user-error "No flymake problem for current line")))
         (menu (mapcar (lambda (ov)
                         (let ((diag (overlay-get ov 'flymake--diagnostic)))
                           (cons (flymake--diag-text diag)
                                 ov)))
                       diag-overlays))
         (event (if (mouse-event-p event)
                    event
                  (list 'mouse-1 (posn-at-point))))
         (diagnostics (mapcar (lambda (ov) (overlay-get ov 'flymake--diagnostic))
                              diag-overlays))
         (title (format "Line %d: %d error(s), %d other(s)"
                        (line-number-at-pos)
                        (cl-count-if #'flymake--diag-errorp diagnostics)
                        (cl-count-if-not #'flymake--diag-errorp diagnostics)))
         (choice (x-popup-menu event (list title (cons "" menu)))))
    (flymake-log 3 "choice=%s" choice)
    ;; FIXME: What is the point of going to the problem locus if we're
    ;; certainly already there?
    ;;
    (when choice (goto-char (overlay-start choice)))))

;; flymake minor mode declarations
(defvar-local flymake-mode-line nil)
(defvar-local flymake-mode-line-e-w nil)
(defvar-local flymake-mode-line-status nil)

(defun flymake-report-status (e-w &optional status)
  "Show status in mode line."
  (when e-w
    (setq flymake-mode-line-e-w e-w))
  (when status
    (setq flymake-mode-line-status status))
  (let* ((mode-line " Flymake"))
    (when (> (length flymake-mode-line-e-w) 0)
      (setq mode-line (concat mode-line ":" flymake-mode-line-e-w)))
    (setq mode-line (concat mode-line flymake-mode-line-status))
    (setq flymake-mode-line mode-line)
    (force-mode-line-update)))

;; Nothing in flymake uses this at all any more, so this is just for
;; third-party compatibility.
(define-obsolete-function-alias 'flymake-display-warning 'message-box "26.1")

(defun flymake-report-fatal-status (status warning)
  "Display a warning and switch flymake mode off."
  ;; This first message was always shown by default, and flymake-log
  ;; does nothing by default, hence the use of message.
  ;; Another option is display-warning.
  (if (< flymake-log-level 0)
      (message "Flymake: %s. Flymake will be switched OFF" warning))
  (flymake-mode 0)
  (flymake-log 0 "switched OFF Flymake mode for buffer %s due to fatal status %s, warning %s"
               (buffer-name) status warning))

(defun flymake-report (diagnostics)
  (save-restriction
    (widen)
    (flymake-delete-own-overlays)
    (mapc #'flymake--highlight-line diagnostics)
    (let ((err-count (cl-count-if #'flymake--diag-errorp diagnostics))
          (warn-count (cl-count-if-not #'flymake--diag-errorp diagnostics)))
      (when flymake-check-start-time
        (flymake-log 2 "%s: %d error(s), %d other(s) in %.2f second(s)"
                     (buffer-name) err-count warn-count
                     (- (float-time) flymake-check-start-time)))
      (if (null diagnostics)
          (flymake-report-status "" "")
        (flymake-report-status (format "%d/%d" err-count warn-count) "")))))

(defvar-local flymake--backend nil
  "The currently active backend selected by `flymake-mode'")

(defun flymake--can-syntax-check-buffer (buffer)
  (catch 'done
    (dolist (candidate flymake-backends)
      (when (with-current-buffer buffer (funcall (car candidate)))
      (throw 'done (cdr candidate))))))

(defun flymake--start-syntax-check (&optional deferred)
  (cl-labels ((start
               ()
               (remove-hook 'post-command-hook #'start 'local)
               (setq flymake-check-start-time (float-time))
               (funcall flymake--backend)))
    (if (and deferred
             this-command)
        (add-hook 'post-command-hook #'start 'append 'local)
      (start))))

;;;###autoload
(define-minor-mode flymake-mode nil
  :group 'flymake :lighter flymake-mode-line
  (cond

   ;; Turning the mode ON.
   (flymake-mode
    (let* ((backend (flymake--can-syntax-check-buffer (current-buffer))))
      (cond
       ((not backend)
        (flymake-log 2 "flymake cannot check syntax in buffer %s" (buffer-name)))
       (t
        (setq flymake--backend backend)

        (add-hook 'after-change-functions 'flymake-after-change-function nil t)
        (add-hook 'after-save-hook 'flymake-after-save-hook nil t)
        (add-hook 'kill-buffer-hook 'flymake-kill-buffer-hook nil t)
        ;;+(add-hook 'find-file-hook 'flymake-find-file-hook)

        (flymake-report-status "" "")

        (setq flymake-timer
              (run-at-time nil 1 'flymake-on-timer-event (current-buffer)))

        (when (and flymake-start-syntax-check-on-find-file
                   ;; Since we write temp files in current dir, there's no point
                   ;; trying if the directory is read-only (bug#8954).
                   (file-writable-p (file-name-directory buffer-file-name)))
          (with-demoted-errors
              (flymake--start-syntax-check)))))
      )
    )

   ;; Turning the mode OFF.
   (t
    (setq flymake--backend nil)

    (remove-hook 'after-change-functions 'flymake-after-change-function t)
    (remove-hook 'after-save-hook 'flymake-after-save-hook t)
    (remove-hook 'kill-buffer-hook 'flymake-kill-buffer-hook t)
    ;;+(remove-hook 'find-file-hook (function flymake-find-file-hook) t)

    (flymake-delete-own-overlays)

    (when flymake-timer
      (cancel-timer flymake-timer)
      (setq flymake-timer nil))

    (setq flymake-is-running nil))))

;;;###autoload
(defun flymake-mode-on ()
  "Turn flymake mode on."
  (flymake-mode 1)
  (flymake-log 1 "flymake mode turned ON for buffer %s" (buffer-name)))

;;;###autoload
(defun flymake-mode-off ()
  "Turn flymake mode off."
  (flymake-mode 0)
  (flymake-log 1 "flymake mode turned OFF for buffer %s" (buffer-name)))

(defun flymake-after-change-function (start stop _len)
  "Start syntax check for current buffer if it isn't already running."
  ;;+(flymake-log 0 "setting change time to %s" (float-time))
  (let((new-text (buffer-substring start stop)))
    (when (and flymake-start-syntax-check-on-newline (equal new-text "\n"))
      (flymake-log 3 "starting syntax check as new-line has been seen")
      (flymake--start-syntax-check 'deferred))
    (setq flymake-last-change-time (float-time))))

(defun flymake-after-save-hook ()
  (if (local-variable-p 'flymake-mode (current-buffer))	; (???) other way to determine whether flymake is active in buffer being saved?
      (progn
	(flymake-log 3 "starting syntax check as buffer was saved")
	(flymake--start-syntax-check)))) ; no more mode 3. cannot start check if mode 3 (to temp copies) is active - (???)

(defun flymake-kill-buffer-hook ()
  (when flymake-timer
    (cancel-timer flymake-timer)
    (setq flymake-timer nil)))

;;;###autoload
(defun flymake-find-file-hook ()
  (when (and (not (local-variable-p 'flymake-mode (current-buffer)))
	     (flymake--can-syntax-check-buffer (current-buffer)))
    (flymake-mode)
    (flymake-log 3 "automatically turned ON flymake mode")))

(defun flymake-goto-next-error (&optional n interactive)
  "Go to next, or Nth next, flymake error in buffer."
  (interactive (list 1 t))
  (let* ((n (or n 1))
         (ovs (flymake--overlays :filter 'flymake--diagnostic
                                 :compare (if (cl-plusp n) #'< #'>)
                                 :key #'overlay-start))
         (chain (cl-member-if (lambda (ov)
                                (if (cl-plusp n)
                                    (> (overlay-start ov)
                                       (point))
                                  (< (overlay-start ov)
                                     (point))))
                              ovs))
         (target (nth (1- n) chain)))
    (cond (target
           (goto-char (overlay-start target))
           (when interactive
             (message
              (funcall (overlay-get target 'help-echo)
                       nil nil (point)))))
          (interactive
           (user-error "No more flymake errors")))))

(defun flymake-goto-prev-error (&optional n interactive)
  "Go to previous, or Nth previous, flymake error in buffer."
  (interactive (list 1 t))
  (flymake-goto-next-error (- (or n 1)) interactive))

(provide 'flymake-ui)
;;; flymake-ui.el ends here
