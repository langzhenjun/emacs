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
(require 'warnings) ; warning-numeric-level, display-warning
(require 'compile) ; for some faces
(eval-when-compile (require 'subr-x)) ; when-let*, if-let*

(defgroup flymake nil
  "Universal on-the-fly syntax checker."
  :version "23.1"
  :link '(custom-manual "(flymake) Top")
  :group 'tools)

(defcustom flymake-error-bitmap '(flymake-double-exclamation-mark
                                  compilation-error)
  "Bitmap (a symbol) used in the fringe for indicating errors.
The value may also be a list of two elements where the second
element specifies the face for the bitmap.  For possible bitmap
symbols, see `fringe-bitmaps'.  See also `flymake-warning-bitmap'.

The option `flymake-fringe-indicator-position' controls how and where
this is used."
  :version "24.3"
  :type '(choice (symbol :tag "Bitmap")
                 (list :tag "Bitmap and face"
                       (symbol :tag "Bitmap")
                       (face :tag "Face"))))

(defcustom flymake-warning-bitmap '(exclamation-mark compilation-warning)
  "Bitmap (a symbol) used in the fringe for indicating warnings.
The value may also be a list of two elements where the second
element specifies the face for the bitmap.  For possible bitmap
symbols, see `fringe-bitmaps'.  See also `flymake-error-bitmap'.

The option `flymake-fringe-indicator-position' controls how and where
this is used."
  :version "24.3"
  :type '(choice (symbol :tag "Bitmap")
                 (list :tag "Bitmap and face"
                       (symbol :tag "Bitmap")
                       (face :tag "Face"))))

(defcustom flymake-note-bitmap '(exclamation-mark compilation-info)
  "Bitmap (a symbol) used in the fringe for indicating info notes.
The value may also be a list of two elements where the second
element specifies the face for the bitmap.  For possible bitmap
symbols, see `fringe-bitmaps'.  See also `flymake-error-bitmap'.

The option `flymake-fringe-indicator-position' controls how and where
this is used."
  :version "26.1"
  :type '(choice (symbol :tag "Bitmap")
                 (list :tag "Bitmap and face"
                       (symbol :tag "Bitmap")
                       (face :tag "Face"))))

(defcustom flymake-fringe-indicator-position 'left-fringe
  "The position to put flymake fringe indicator.
The value can be nil (do not use indicators), `left-fringe' or `right-fringe'.
See `flymake-error-bitmap' and `flymake-warning-bitmap'."
  :version "24.3"
  :type '(choice (const left-fringe)
		 (const right-fringe)
		 (const :tag "No fringe indicators" nil)))

(defcustom flymake-start-syntax-check-on-newline t
  "Start syntax check if newline char was added/removed from the buffer."
  :type 'boolean)

(defcustom flymake-no-changes-timeout 0.5
  "Time to wait after last change before starting compilation."
  :type 'number)

(defcustom flymake-gui-warnings-enabled t
  "Enables/disables GUI warnings."
  :type 'boolean)
(make-obsolete-variable 'flymake-gui-warnings-enabled
			"it no longer has any effect." "26.1")

(defcustom flymake-start-syntax-check-on-find-file t
  "Start syntax check on find file."
  :type 'boolean)

(defcustom flymake-log-level -1
  "Logging level, only messages with level lower or equal will be logged.
-1 = NONE, 0 = ERROR, 1 = WARNING, 2 = INFO, 3 = DEBUG"
  :type 'integer)
(make-obsolete-variable 'flymake-log-level
			"it is superseded by `warning-minimum-log-level.'"
                        "26.1")

(defcustom flymake-wrap-around t
  "If non-nil, moving to errors wraps around buffer boundaries."
  :type 'boolean)

(define-fringe-bitmap 'flymake-double-exclamation-mark
  (vector #b00000000
          #b00000000
          #b00000000
          #b00000000
          #b01100110
          #b01100110
          #b01100110
          #b01100110
          #b01100110
          #b01100110
          #b01100110
          #b01100110
          #b00000000
          #b01100110
          #b00000000
          #b00000000
          #b00000000))

(defvar-local flymake-timer nil
  "Timer for starting syntax check.")

(defvar-local flymake-last-change-time nil
  "Time of last buffer change.")

(defvar-local flymake-check-start-time nil
  "Time at which syntax check was started.")

(defun flymake-log (level text &rest args)
  "Log a message at level LEVEL.
If LEVEL is higher than `flymake-log-level', the message is
ignored.  Otherwise, it is printed using `message'.
TEXT is a format control string, and the remaining arguments ARGS
are the string substitutions (see the function `format')."
  (let* ((msg (apply #'format-message text args))
         (warning-minimum-level :emergency))
    (display-warning
     'flymake
     (format "%s: %s" (buffer-name) msg)
     (if (numberp level)
         (or (nth level
                  '(:error :warning :debug :debug) )
             :error)
       level)
     "*Flymake log*")))

(defun flymake-error (text &rest args)
  "Signal an error for flymake."
  (let ((msg (apply #'format-message text args)))
    (flymake-log :error msg)
    (error (concat "[flymake] " msg))))

(cl-defstruct (flymake--diag
               (:constructor flymake--diag-make))
  buffer beg end type text backend)

(defun flymake-make-diagnostic (buffer
                                beg
                                end
                                type
                                text)
  "Make a flymake diagnostic for BUFFER's region from BEG to END.
TYPE is a key to `flymake-diagnostic-types-alist' and TEXT is a
description of the problem detected in this region."
  (flymake--diag-make :buffer buffer :beg beg :end end :type type :text text))

(defun flymake-ler-make-ler (file line type text &optional full-file)
  (let* ((file (or full-file file))
         (buf (find-buffer-visiting file)))
    (unless buf (flymake-error "No buffer visiting %s" file))
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
verify FILTER, a function, and sort them by COMPARE (using KEY)."
  (save-restriction
    (widen)
    (let ((ovs (cl-remove-if-not
                (lambda (ov)
                  (and (overlay-get ov 'flymake)
                       (or (not filter)
                           (funcall filter ov))))
                (if (and beg (null end))
                    (overlays-at beg t)
                  (overlays-in (or beg (point-min))
                               (or end (point-max)))))))
      (if compare
          (cl-sort ovs compare :key (or key
                                        #'identity))
        ovs))))

(defun flymake-delete-own-overlays (&optional filter)
  "Delete all flymake overlays in BUFFER."
  (mapc #'delete-overlay (flymake--overlays :filter filter)))

(defface flymake-error
  '((((supports :underline (:style wave)))
     :underline (:style wave :color "Red1"))
    (t
     :inherit error))
  "Face used for marking error regions."
  :version "24.4")

(defface flymake-warning
  '((((supports :underline (:style wave)))
     :underline (:style wave :color "deep sky blue"))
    (t
     :inherit warning))
  "Face used for marking warning regions."
  :version "24.4")

(defface flymake-note
  '((((supports :underline (:style wave)))
     :underline (:style wave :color "yellow green"))
    (t
     :inherit warning))
  "Face used for marking note regions."
  :version "26.1")

(define-obsolete-face-alias 'flymake-warnline 'flymake-warning "26.1")
(define-obsolete-face-alias 'flymake-errline 'flymake-error "26.1")

(defun flymake-diag-region (line &optional col)
  "Compute region (BEG . END) corresponding to LINE and COL.
If COL is nil, return a region just for LINE.
Return nil if the region is invalid."
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
            (if (and col (cl-plusp col))
                (let* ((beg (progn (forward-char (1- col))
                                   (point)))
                       (sexp-end (ignore-errors (end-of-thing 'sexp)))
                       (end (or (and sexp-end
                                     (not (= sexp-end beg))
                                     sexp-end)
                                (ignore-errors (goto-char (1+ beg)))))
                       (safe-end (or end
                                     (fallback-eol beg))))
                  (cons (if end beg (fallback-bol))
                        safe-end))
              (let* ((beg (fallback-bol))
                     (end (fallback-eol beg)))
                (cons beg end))))))
    (error (flymake-error "Invalid region line=%s col=%s" line col))))

(defvar flymake-diagnostic-functions nil
  "Special hook of Flymake backends to check a buffer.

The functions in this hook diagnose problems in a buffer’s
contents and provide the Flymake user interface with information
about where and how to annotate problems diagnosed in a buffer.

Whenever Flymake or the user decides to re-check the buffer, each
function is called with a common calling convention, a single
REPORT-FN argument, detailed below.  Backend functions are first
expected to quickly and inexpensively announce the feasibility of
checking the buffer via the return value (i.e. they aren't
required to immediately start checking the buffer):

* If the backend function returns nil, Flymake forgets about this
  backend for the current check, but will call it again for the
  next one;

* If the backend function returns non-nil, Flymake expects this
  backend to check the buffer and call its REPORT-FN callback
  function exactly once.  If the computation involved is
  inexpensive, the backend function may do so synchronously,
  before returning.  If it is not, it should do so after
  returning, using idle timers, asynchronous processes or other
  asynchronous mechanisms.

* If the backend function signals an error, it is disabled,
  i.e. Flymake will not use it again for the current or any
  future checks of this buffer.  Certain commands, like turning
  `flymake-mode' on and off again, resets the list of disabled
  backends.

Backends are required to call REPORT-FN with a single argument
ACTION followed by an optional list of keywords parameters and
their values (:KEY1 VALUE1 :KEY2 VALUE2...).

The possible values for ACTION are.

* A (possibly empty) list of objects created with
  `flymake-make-diagnostic', causing Flymake to annotate the
  buffer with this information and consider the backend has
  having finished its check normally.

* The symbol `:progress', signalling that the backend is still
  working and will call REPORT-FN again in the future.

* The symbol `:panic', signalling that the backend has
  encountered an exceptional situation and should be disabled.

The recognized optional keyword arguments are:

* ‘:explanation’: value should give user-readable details of
  the situation encountered, if any.

* ‘:force’: value should be a boolean forcing the Flymake UI
  to consider the report even if was somehow unexpected.")

(defvar flymake-diagnostic-types-alist
  `((:error
     . ((category . flymake-error)
        (mode-line-face . compilation-error)))
    (:warning
     . ((category . flymake-warning)
        (mode-line-face . compilation-warning)))
    (:note
     . ((category . flymake-note)
        (mode-line-face . compilation-info))))
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
(put 'flymake-error 'bitmap 'flymake-error-bitmap)
(put 'flymake-error 'severity (warning-numeric-level :error))

(put 'flymake-warning 'face 'flymake-warning)
(put 'flymake-warning 'bitmap 'flymake-warning-bitmap)
(put 'flymake-warning 'severity (warning-numeric-level :warning))

(put 'flymake-note 'face 'flymake-note)
(put 'flymake-note 'bitmap 'flymake-note-bitmap)
(put 'flymake-note 'severity (warning-numeric-level :debug))

(defun flymake--lookup-type-property (type prop &optional default)
  "Look up PROP for TYPE in `flymake-diagnostic-types-alist'.
If TYPE doesn't declare PROP in either
`flymake-diagnostic-types-alist' or its associated category,
return DEFAULT."
  (let ((alist-probe (assoc type flymake-diagnostic-types-alist)))
    (cond (alist-probe
           (let* ((alist (cdr alist-probe))
                  (prop-probe (assoc prop alist)))
             (if prop-probe
                 (cdr prop-probe)
               (if-let* ((cat (assoc-default 'category alist))
                         (plist (and (symbolp cat)
                                     (symbol-plist cat)))
                         (cat-probe (plist-member plist prop)))
                   (cadr cat-probe)
                 default))))
          (t
           default))))

(defun flymake--fringe-overlay-spec (bitmap &optional recursed)
  (if (and (symbolp bitmap)
           (boundp bitmap)
           (not recursed))
      (flymake--fringe-overlay-spec
       (symbol-value bitmap) t)
    (and flymake-fringe-indicator-position
         bitmap
         (propertize "!" 'display
                     (cons flymake-fringe-indicator-position
                           (if (listp bitmap)
                               bitmap
                             (list bitmap)))))))

(defun flymake--highlight-line (diagnostic)
  "Highlight buffer with info in DIAGNOSTIC."
  (when-let* ((ov (make-overlay
                   (flymake--diag-beg diagnostic)
                   (flymake--diag-end diagnostic))))
    ;; First copy over to ov every property in the relevant alist.
    ;;
    (cl-loop for (k . v) in
             (assoc-default (flymake--diag-type diagnostic)
                            flymake-diagnostic-types-alist)
             do (overlay-put ov k v))
    ;; Now ensure some defaults are set
    ;;
    (cl-flet ((default-maybe
                (prop value)
                (unless (or (plist-member (overlay-properties ov) prop)
                            (let ((cat (overlay-get ov 'category)))
                              (and cat
                                   (plist-member (symbol-plist cat) prop))))
                  (overlay-put ov prop value))))
      (default-maybe 'bitmap 'flymake-error-bitmap)
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
    (overlay-put ov 'flymake t)
    (overlay-put ov 'flymake--diagnostic diagnostic)))

(defun flymake-on-timer-event (buffer)
  "Start a syntax check for buffer BUFFER if necessary."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and flymake-mode
		 flymake-last-change-time
		 (> (- (float-time) flymake-last-change-time)
                    flymake-no-changes-timeout))

	(setq flymake-last-change-time nil)
	(flymake-log 3 "starting syntax check as more than 1 second passed since last change")
	(flymake-start)))))

;; Nothing in flymake uses this at all any more, so this is just for
;; third-party compatibility.
(define-obsolete-function-alias 'flymake-display-warning 'message-box "26.1")

(defvar-local flymake--running-backends nil
  "List of currently active flymake backends.
An active backend is a member of `flymake-diagnostic-functions'
that has been invoked but hasn't reported any final status yet.")

(defvar-local flymake--disabled-backends nil
  "List of currently disabled flymake backends.
A backend is disabled if it reported `:panic'.")

(defvar-local flymake--diagnostics-table nil
  "Hash table of all diagnostics indexed by backend.")

(defun flymake-is-running ()
  "Tell if flymake has running backends in this buffer"
  flymake--running-backends)

(defun flymake--disable-backend (backend action &optional explanation)
  (cl-pushnew backend flymake--disabled-backends)
  (flymake-log 0 "Disabled the backend %s due to reports of %s (%s)"
               backend action explanation))

(cl-defun flymake--handle-report (backend action &key explanation force)
  "Handle reports from flymake backend identified by BACKEND.

BACKEND, ACTION and EXPLANATION conform to the calling convention
described in `flymake-diagnostic-functions' (which see). Optional
FORCE says to handle a report even if it was not expected."
  (cond
   ((and (not (memq backend flymake--running-backends))
         (not force))
    (flymake-error "Ignoring unexpected report from backend %s" backend))
   ((eq action :progress)
    (flymake-log 3 "Backend %s reports progress: %s" backend explanation))
   ((eq :panic action)
    (flymake--disable-backend backend action explanation))
   ((listp action)
    (let ((diagnostics action))
      (save-restriction
        (widen)
        (flymake-delete-own-overlays
         (lambda (ov)
           (eq backend
               (flymake--diag-backend
                (overlay-get ov 'flymake--diagnostic)))))
        (puthash backend diagnostics flymake--diagnostics-table)
        (mapc (lambda (diag)
                (flymake--highlight-line diag)
                (setf (flymake--diag-backend diag) backend))
              diagnostics)
        (when flymake-check-start-time
          (flymake-log 2 "backend %s reported %d diagnostics in %.2f second(s)"
                       backend
                       (length diagnostics)
                       (- (float-time) flymake-check-start-time))))))
   (t
    (flymake--disable-backend "?"
                              :strange
                              (format "unknown action %s (%s)"
                                      action explanation))))
  (unless (eq action :progress)
    (flymake--stop-backend backend)))

(defun flymake-make-report-fn (backend)
  "Make a suitable anonymous report function for BACKEND.
BACKEND is used to help flymake distinguish diagnostic
sources."
  (lambda (&rest args)
    (apply #'flymake--handle-report backend args)))

(defun flymake--stop-backend (backend)
  "Stop the backend BACKEND."
  (setq flymake--running-backends (delq backend flymake--running-backends)))

(defun flymake--run-backend (backend)
  "Run the backend BACKEND."
  (push backend flymake--running-backends)
  (remhash backend flymake--diagnostics-table)
  ;; FIXME: Should use `condition-case-unless-debug' here, but that
  ;; won't let me catch errors from inside `ert-deftest' where
  ;; `debug-on-error' is always t
  (condition-case err
      (unless (funcall backend
                       (flymake-make-report-fn backend))
        (flymake--stop-backend backend))
    (error
     (flymake--disable-backend backend :error
                               err)
     (flymake--stop-backend backend))))

(defun flymake-start (&optional deferred interactive)
  "Start a syntax check.
Start it immediately, or after current command if DEFERRED is
non-nil.  With optional INTERACTIVE or interactively, clear any
stale information about running and automatically disabled
backends."
  (interactive (list nil t))
  (cl-labels
      ((start
        ()
        (remove-hook 'post-command-hook #'start 'local)
        (setq flymake-check-start-time (float-time))
        (when interactive
          (setq flymake--diagnostics-table (make-hash-table)
                flymake--running-backends nil
                flymake--disabled-backends nil))
        (run-hook-wrapped
         'flymake-diagnostic-functions
         (lambda (backend)
           (cond ((memq backend flymake--running-backends)
                  (flymake-log 2 "Backend %s still running, not restarting"
                               backend))
                 ((memq backend flymake--disabled-backends)
                  (flymake-log 2 "Backend %s is disabled, not starting"
                               backend))
                 (t
                  (flymake--run-backend backend)))
           nil))))
    (if (and deferred
             this-command)
        (add-hook 'post-command-hook #'start 'append 'local)
      (start))))

(define-minor-mode flymake-mode nil
  :group 'flymake :lighter flymake--mode-line-format
  (setq flymake--running-backends nil
        flymake--disabled-backends nil)
  (cond
   ;; Turning the mode ON.
   (flymake-mode
    (cond
     ((not flymake-diagnostic-functions)
      (flymake-error "No backends to check buffer %s" (buffer-name)))
     (t
      (add-hook 'after-change-functions 'flymake-after-change-function nil t)
      (add-hook 'after-save-hook 'flymake-after-save-hook nil t)
      (add-hook 'kill-buffer-hook 'flymake-kill-buffer-hook nil t)

      (setq flymake-timer
            (run-at-time nil 1 'flymake-on-timer-event (current-buffer)))
      (setq flymake--diagnostics-table (make-hash-table))

      (when flymake-start-syntax-check-on-find-file
        (flymake-start)))))

   ;; Turning the mode OFF.
   (t
    (remove-hook 'after-change-functions 'flymake-after-change-function t)
    (remove-hook 'after-save-hook 'flymake-after-save-hook t)
    (remove-hook 'kill-buffer-hook 'flymake-kill-buffer-hook t)
    ;;+(remove-hook 'find-file-hook (function flymake-find-file-hook) t)

    (flymake-delete-own-overlays)

    (when flymake-timer
      (cancel-timer flymake-timer)
      (setq flymake-timer nil)))))

(defun flymake-mode-on ()
  "Turn flymake mode on."
  (flymake-mode 1)
  (flymake-log 1 "flymake mode turned ON"))

(defun flymake-mode-off ()
  "Turn flymake mode off."
  (flymake-mode 0)
  (flymake-log 1 "flymake mode turned OFF"))

(make-obsolete 'flymake-mode-on 'flymake-mode "26.1")
(make-obsolete 'flymake-mode-off 'flymake-mode "26.1")

(defun flymake-after-change-function (start stop _len)
  "Start syntax check for current buffer if it isn't already running."
  ;;+(flymake-log 0 "setting change time to %s" (float-time))
  (let((new-text (buffer-substring start stop)))
    (when (and flymake-start-syntax-check-on-newline (equal new-text "\n"))
      (flymake-log 3 "starting syntax check as new-line has been seen")
      (flymake-start 'deferred))
    (setq flymake-last-change-time (float-time))))

(defun flymake-after-save-hook ()
  (when flymake-mode
    (flymake-log 3 "starting syntax check as buffer was saved")
    (flymake-start))) ; no more mode 3. cannot start check if mode 3 (to temp copies) is active - (???)

(defun flymake-kill-buffer-hook ()
  (when flymake-timer
    (cancel-timer flymake-timer)
    (setq flymake-timer nil)))

(defun flymake-find-file-hook ()
  (unless (or flymake-mode
              (null flymake-diagnostic-functions))
    (flymake-mode)
    (flymake-log 3 "automatically turned ON")))

(defun flymake-goto-next-error (&optional n filter interactive)
  "Go to Nth next flymake error in buffer matching FILTER.

Interactively, always move to the next error.  Interactively, and
with a prefix arg, skip any diagnostics with a severity less than
‘:warning’.

If ‘flymake-wrap-around’ is non-nil, resumes search from top
at end of buffer.

FILTER is a list of diagnostic types found in
`flymake-diagnostic-types-alist', or nil, if no filter is to be
applied."
  ;; TODO: let filter be a number, a severity below which diags are
  ;; skipped.
  (interactive (list 1
                     (if current-prefix-arg
                         '(:error :warning))
                     t))
  (let* ((n (or n 1))
         (ovs (flymake--overlays :filter
                                 (lambda (ov)
                                   (let ((diag (overlay-get
                                                ov
                                                'flymake--diagnostic)))
                                     (and diag
                                          (or (not filter)
                                              (memq (flymake--diag-type diag)
                                                    filter)))))
                                 :compare (if (cl-plusp n) #'< #'>)
                                 :key #'overlay-start))
         (tail (cl-member-if (lambda (ov)
                               (if (cl-plusp n)
                                   (> (overlay-start ov)
                                      (point))
                                 (< (overlay-start ov)
                                    (point))))
                             ovs))
         (chain (if flymake-wrap-around
                    (if tail
                        (progn (setcdr (last tail) ovs) tail)
                      (and ovs (setcdr (last ovs) ovs)))
                  tail))
         (target (nth (1- n) chain)))
    (cond (target
           (goto-char (overlay-start target))
           (when interactive
             (message
              (funcall (overlay-get target 'help-echo)
                       nil nil (point)))))
          (interactive
           (user-error "No more flymake errors%s"
                       (if filter
                           (format " of types %s" filter)
                         ""))))))

(defun flymake-goto-prev-error (&optional n filter interactive)
  "Go to Nth previous flymake error in buffer matching FILTER.

Interactively, always move to the previous error.  Interactively,
and with a prefix arg, skip any diagnostics with a severity less
than ‘:warning’.

If ‘flymake-wrap-around’ is non-nil, resumes search from top
at end of buffer.

FILTER is a list of diagnostic types found in
`flymake-diagnostic-types-alist', or nil, if no filter is to be
applied."
  (interactive (list 1 (if current-prefix-arg
                           '(:error :warning))
                     t))
  (flymake-goto-next-error (- (or n 1)) filter interactive))


;;; Mode-line fanciness
;;;
(defvar flymake--mode-line-format `(:eval (flymake--mode-line-format)))

(put 'flymake--mode-line-format 'risky-local-variable t)

(defun flymake--mode-line-format ()
  "Produce a pretty minor mode indicator."
  (let ((running flymake--running-backends)
        (reported (cl-plusp
                   (hash-table-count flymake--diagnostics-table))))
    `((:propertize " Flymake"
                   mouse-face mode-line-highlight
                   ,@(when (not reported)
                       `(face compilation-mode-line-fail))
                   help-echo
                   ,(concat (format "%s registered backends\n"
                                    (length flymake-diagnostic-functions))
                            (format "%s running\n"
                                    (length running))
                            (format "%s disabled\n"
                                    (length flymake--disabled-backends))
                            "mouse-1: go to log buffer ")
                   keymap
                   ,(let ((map (make-sparse-keymap)))
                      (define-key map [mode-line mouse-1]
                        (lambda (_event)
                          (interactive "e")
                          (switch-to-buffer "*Flymake log*")))
                      map))
      ,@(when running
          `(":" (:propertize "Run"
                             face compilation-mode-line-run
                             help-echo
                             ,(format "%s running backends"
                                      (length running)))))
      ,@(when reported
          (let ((by-type (make-hash-table)))
            (maphash (lambda (_backend diags)
                       (mapc (lambda (diag)
                               (push diag
                                     (gethash (flymake--diag-type diag)
                                              by-type)))
                             diags))
                     flymake--diagnostics-table)
            (cl-loop
             for type in
             (mapcar #'car flymake-diagnostic-types-alist)
             for diags = (gethash type by-type)
             for face = (flymake--lookup-type-property type
                                                       'mode-line-face
                                                       'compilation-error)
             for severity = (flymake--lookup-type-property
                             type
                             'severity
                             (warning-numeric-level :error))
             when (or diags
                      (>= severity (warning-numeric-level :warning)))
             collect `(:propertize
                       ,(format "%d" (length diags))
                       face ,face
                       mouse-face mode-line-highlight
                       keymap
                       ,(let ((map (make-sparse-keymap))
                              (type type))
                          (define-key map [mode-line mouse-4]
                            (lambda (_event)
                              (interactive "e")
                              (flymake-goto-prev-error 1 (list type) t)))
                          (define-key map [mode-line mouse-5]
                            (lambda (_event)
                              (interactive "e")
                              (flymake-goto-next-error 1 (list type) t)))
                          map)
                       help-echo
                       ,(concat (format "%s diagnostics of type %s\n"
                                        (propertize (format "%d"
                                                            (length diags))
                                                    'face face)
                                        (propertize (format "%s" type)
                                                    'face face))
                                "mouse-4/mouse-5: previous/next of this type\n"))
             into forms
             finally return
             `((:propertize "[")
               ,@(cl-loop for (a . rest) on forms by #'cdr
                          collect a when rest collect
                          '(:propertize " "))
               (:propertize "]"))))))))




(provide 'flymake-ui)
;;; flymake-ui.el ends here
