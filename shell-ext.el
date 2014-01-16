;;; shell-ext.el --- Extensions for shell-mode       -*- lexical-binding: t; -*-

;; This file is NOT part of GNU Emacs.

;; Copyright (C) 2014  Rodrigo Lazo

;; Author: Rodrigo Lazo <rlazo.paz@gmail.com>
;; Keywords: terminals, extensions

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 2 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; shell-ext enhances shell-mode with better extensibility by adding a
;; command processing pipeline. This pipeline enables the execution of
;; custom code before sending commands to the underlying shell
;; process. It also enables command interception, so you could invoke
;; emacs functions from the shell, e.g. issuing the command "man
;; emacs" can launch emacs' man-mode instead of the actual man
;; program.

;; Usage
;; =====
;;
;; Put shell-ext.el anywhere in your load-path and then require it.
;;
;;   (require 'shell-ext)
;;
;; that's it!

;; Available functions
;; =====================
;;
;; Pre-processing
;; --------------
;;
;; `shell-ext-preprocessor--sudoize-apt-get' automatically prepends
;; sudo to all apt-get commands
;;
;; `shell-ext-preprocessor--rename-shell' renames the shell buffer
;; according to the comand. The alist mapping commands to buffer names
;; is `shell-ext-preprocessors-options-rename-shell-alist'. Also, for
;; more control over the final shell buf-name, you could define your own
;; function at
;; `shell-ext-preprocessors-options-rename-shell-fun'. *NOTE* the
;; shell buffer will keep its new buf-name even after the command has
;; finished.
;;
;; `shell-ext-preprocessor--cat' replaces '<' with 'cat'

;; Processing
;; ----------
;;
;; `shell-ext-processor--eval' evaluates the input as a lisp
;; expression. For example, 'e (+ 1 2)' will print '3'
;;
;; `shell-ext-processor--calc-eval' evaluates the input as a calc
;; expression. For example, '= sin(90)' will print '1' or = 2' + 59'
;; will print 1@ 1' 0"
;;
;; `shell-ext-processor--find-file' visits a file. For example, 'ff
;; readme.txt' will visit readme.txt in other window.
;;
;; `shell-ext-processor--man' opens manpages using emacs instead of
;; man. For example, 'man emacs' will open the emacs man page in other
;; window.


;; Implementing custom functions
;; =============================
;;
;; Before implementing custom functions, please check out the helper
;; macros/functions defined in this file. Mainly, do not use `insert'
;; directly, instead rely on `shell-ext--insert'.
;;
;; Functions/vars with prefix `shell-ext-' are meant to be used or
;; customized by the user. Functions/vars with prefix `shell-ext--'
;; are meant to be used by extension writters.
;;
;; Pre-processing
;; -------------
;;
;; This step modifies the command string if needed. Every function
;; registered in `shell-ext-preprocessors' is run in order
;; for every command. Pre-processors must accept as input the command
;; string and return the modified string. If a pre-processor returns
;; nil or empty string, the pipeline is finished and the command
;; ignored.

;; Processing
;; ----------
;;
;; Processors are registered in the `shell-ext-processors'
;; alist, and only the one that matches the command is run. They
;; receive as input the list of arguments given to the command and
;; they must return T if they *do not* want the command to be send
;; to the underlying shell process, and NIL otherwise.
;;
;; if a processor wants to show a new buffer, it should open it in the
;; same window the shell is running on, and leave it as the current
;; one. The pipeline will then open that buffer in a different
;; window. For example, if you want to visit a file, you should use
;; `find-file' instead of `find-file-other-window'.

;; Known issues
;; ============
;;
;; - No support for pipelined commands, they are considered a single
;;      command.

;; Have fun!

;;; Code:

(require 'pp)

;;;; Custom

(defgroup shell-ext nil
  "Shell mode extensions."
  :prefix "shell-ext-"
  :group 'tools)

(defcustom shell-ext-preprocessors
  '(shell-ext-preprocessor--sudoize-apt-get
    shell-ext-preprocessor--cat
    shell-ext-preprocessor--rename-shell)
  "Ordered list of functions to be called for command pre-processing.

Pre-processors receive as input the command string and produce as
output the updated command string.

If a pre-processor does not apply to the given command, or does not
modify the command, it should return the string unchanged.

If the return value of a pre-processor is the empty string, or
nil, then the following pre-processors are not executed, the
pipeline is aborted and no command is executed.

Pre-processors are chained, so order matters."
  :group 'shell-ext
  :type '(repeat function))

(defcustom shell-ext-processors
  '(("ff"  . shell-ext-processor--find-file)
    ("e"   . shell-ext-processor--eval)
    ("="   . shell-ext-processor--calc-eval)
    ("man" . shell-ext-processor--man))
  "Alist of command name to processor function.

Processors receive as input the tokenized command string minus
the command itself. Output value must be a T if the command
should be passed to the underlying shell process, and NIL
otherwise.

Any modifications to the command arguments are ignored.

Only one processor per command is executed. If two, or more,
processors are declared for the same command, only the first
one is executed."
  :group 'shell-ext
  :type '(alist :key-type string :value-type function))

(defgroup shell-ext-preprocessors-options nil
  "Customization options available for some preprocessors"
  :tag "Pre-processors options"
  :group 'shell-ext)

(defcustom shell-ext-preprocessors-options-rename-shell-fun
  'shell-ext--compute-new-shell-buffer-name
  "Function invoked by `shell-ext-preprocessor--rename-shell' to
compute a new shell buffer name.

This function receives as input the seed buffer name declared in
`shell-ext-preprocessors-options-rename-shell-alist' and it
should return the new buffer name to use. If the return value is
`nil', then the rename preprocessor, and therefore the pipeline,
will be aborted."
  :group 'shell-ext-preprocessors-options
  :type 'function)

(defcustom shell-ext-preprocessors-options-rename-shell-alist
  '(("sudo" . "sudo"))
  "Alist of command name to seed shell name.

For more details about this variable, see
`shell-ext-preprocessors-options-rename-shell-fun'"
  :group 'shell-ext-preprocessors-options
  :type '(alist :key-type string :value-type string))


;;; Pre-processing functions

(defun shell-ext-preprocessor--sudoize-apt-get (cmd)
  "Prepends `sudo' to apt-get commands automatically."
  (if (string-match "^apt-get" cmd)
      (format "sudo %s" cmd)
    cmd))

(defun shell-ext-preprocessor--cat (cmd)
  "Replaces '<' with 'cat'."
  (if (string-match "^<" cmd)
      (format "cat %s" (substring cmd 1))
    cmd))

(defun shell-ext-preprocessor--rename-shell (cmd)
  "Renames the shell based on the command, as defined in
  `shell-ext-preprocessing--rename-shell-alist'"
  (let* ((cmd-name (shell-ext--command-name cmd))
         (seed-name
          (assoc-default cmd-name
                         shell-ext-preprocessors-options-rename-shell-alist)))
    (unless seed-name
      (return cmd))
    (let ((new-buffer-name
           (funcall shell-ext-preprocessors-options-rename-shell-fun
                    seed-name)))
      (cond ((string= new-buffer-name (buffer-name))
             cmd)
            ((buffer-list-matching-re (concat "^" (regexp-quote new-buffer-name) "$"))
             (prog1 nil
               (message "A buffer named \"%s\" already exists, aborting." new-buffer-name)))
            (t
             (rename-buffer new-buffer-name)
             cmd)))))


;;; Processing functions

(defun shell-ext-processor--find-file (args)
  "Finds file passed as first argument"
  (with-shell-ext-ignore
   (let ((filename (car args)))
     (shell-ext--insert "find-file %s" filename)
     (find-file filename))))

(defun shell-ext-processor--eval (args)
  "EVAL's the args.

The result of the evaluation is printed into the shell buffer
unless the evaluation caused the current buffer to change, in
which case nothing is printed.

Evaluation is executed inside a save-excursion block."
  (with-shell-ext-ignore
    (with-demoted-errors
      (save-excursion
        (let ((shell-buffer (current-buffer))
              (out (eval (read (shell-ext--args-to-cmd args))))
              (buffer (current-buffer)))
          (if (eql shell-buffer buffer)
              (shell-ext--pp out)))))))

(defun shell-ext-processor--calc-eval (args)
  "EVAL's the args as calc expressions."
  (with-shell-ext-ignore
    (with-demoted-errors
      (shell-ext--insert
       (calc-eval (shell-ext--args-to-cmd args))))))

(defun shell-ext-processor--man (args)
  "Uses emacs' man instead of the actual man command"
  (with-shell-ext-ignore
   (man (car args))))


;;; Pipeline runner

(defun shell-ext-send (proc cmd)
  "Runs the user command CMD through the extension pipeline"
  (interactive)
  (setq cmd (shell-ext--preprocess (substring-no-properties cmd)))
  (if cmd
      (progn
        (let* ((shell-buffer (current-buffer))
               (ignore (shell-ext--process cmd))
               (buffer (current-buffer)))
          (when (not (eql shell-buffer buffer))
            (switch-to-buffer shell-buffer t t)
            (save-excursion
              (switch-to-buffer-other-window buffer)))
          (comint-simple-send proc (or (and ignore " ") cmd))))
    (comint-simple-send proc " ")))

(defun shell-ext--preprocess (cmd)
  "Runs the preprocessing step over CMD"
  (dolist (preprocessor shell-ext-preprocessors cmd)
    (setq cmd (funcall preprocessor cmd))
    (unless cmd
      (return nil))))

(defun shell-ext--process (cmd)
  "Runs the processing step over CMD"
  (let* ((cmd-name (shell-ext--command-name cmd))
         (cmd-args (shell-ext--command-args cmd))
         (processor (assoc-default cmd-name shell-ext-processors)))
    (when processor
      (funcall processor cmd-args))))


;;;; Helper macros / functions
(defmacro with-shell-ext-ignore (&rest body)
  "Evaluates BODY and returns T. Useful for processing functions
that should be ignored, i.e. not passed to the shell process."
  (declare (indent 0) (debug t))
  `(prog1 t
     ,@body))

(defun shell-ext--command-name (str)
  "Returns the command parsed from STR"
  (car (split-string str)))

(defun shell-ext--command-args (str)
  "Returns the list of command arguments parsed from STR"
  (cdr (split-string str)))

(defun shell-ext--pp (obj)
  "Pretty prints OBJ in the shell buffer"
  (shell-ext--insert
   (with-output-to-string
     (pp obj (current-buffer)))))

(defun shell-ext--insert (str &rest args)
  "Inserts STR formatted using ARGS in the shell buffer"
  (insert (funcall 'format str args))
  (comint-set-process-mark))

(defun shell-ext--args-to-cmd (args)
  "Concats together a list of args into a single command string"
  (mapconcat 'identity args " "))

(defun shell-ext--compute-new-shell-buffer-name (buf-name)
  "Appends -shell to NAME and surrounds it with stars."
  (format "*%s-shell*" buf-name))


;;; Main hook

(add-hook 'shell-mode-hook
          '(lambda()
             (setq comint-input-sender 'shell-ext-send)))

(provide 'shell-ext)
;;; shell-ext.el ends here
