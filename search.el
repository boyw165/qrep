;;; search.el --- Framework of queued search tasks. Support GREP, ACK, AG and more.
;;
;; Copyright (C) 2015
;;
;; Author: boyw165
;; Version: 20150115.1500
;; Package-Requires: ((emacs "24.3") (hl-anything "1.0.0"))
;;
;; This file is NOT part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  I not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; TODO
;; ----
;; * Open with search-result will cause hl-highlight-mode work incorrectly.
;; 
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Change Log:
;;
;; 2015-02-05
;; * Initial release.
;;
;;; Code:

;; GNU library.
(require 'ido)

;; 3rd party libary.
(require 'hl-anything)
(require 'search-result-mode)

(defgroup search nil
  "Search")

(defconst search-default-backends '(("grep" . search-grep-backend)
                                    ;; ("ack" . search-ack-backend)
                                    ;; ("ag" . search-ag-backend)
                                    )
  "Default alist of search backends.")

(defconst search-buffer-name "*Search Result*"
  "Search buffer name.")

(defconst search-temp-buffer-name "*Search Temp*"
  "Temporary search buffer name.")

(defcustom search-backends (nth 0 search-default-backends)
  "Search tool name. Default is GREP."
  :type `(choice ,@(mapcar (lambda (c)
                             `(const :tag ,(car c) ,(car c) ,(cdr c)))
                           search-default-backends)
                 (cons :tag "user defined"
                       (match :tag "exec name"
                               "dummy")
                       (function :tag "command generator function"
                                 search-dummy-backend)))
  :group 'search)

(defun search-set-saved-file (symb val)
  "Setter for `search-saved-file'."
  (when (file-writable-p val)
    (set symb val)
    (add-to-list 'auto-mode-alist
                 `(,(format "\\%s\\'" (file-name-nondirectory val))
                   . search-result-mode))))

;; (add-to-list 'auto-mode-alist '("\\.search\\'" . search-result-mode))
(defcustom search-saved-file (expand-file-name "~/.emacs.d/.search")
  "File for cached search result."
  :type 'string
  :set 'search-set-saved-file
  :group 'search)

(defcustom search-temp-file (expand-file-name "/var/tmp/.search-tmp")
  "Temporary file for search. e.g. as an input file with context of files 
list"
  :type 'string
  :group 'search)

(defcustom search-tasks-max 5
  "Maximum length of the task queue."
  :type 'integer
  :group 'search)

(defcustom search-timer-delay 0.3
  "Delay seconds for every search task."
  :type 'integer
  :group 'search)

(defcustom search-delimiter '(">>>>>>>>>> " . "<<<<<<<<<<<")
  "Maximum length of the task queue."
  :type '(cons (match :tag "open delimiter")
               (match :tag "close delimiter"))
  :group 'search)

(defcustom search-prompt-function 'search-default-prompt-function
  "Prompt function."
  :type 'function
  :group 'search)

(defvar search-tasks nil
  "Search tasks queue.")

(defvar search-tasks-count 0
  "Search tasks count.")

(defvar search-proc nil
  "Search task process.")

(defvar search-timer nil
  "A delay timer for evaluating the queued tasks.")

(defvar search-prompt-timer nil
  "A timer for showing prompt animation.")

(defun search-exec? ()
  "Test whether the necessary exe(s) are present."
  (unless (and (executable-find "sh")
               (executable-find "find")
               (executable-find "xargs")
               (executable-find (car search-backends)))
    (error "%s or xargs is not supported on your system!" (car search-backends))))

;; (defun search-seralize-list (thing)
;;   (cond
;;    ;; A list of strings ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;    ((listp thing)
;;     (let ((it thing)
;;           (space "")
;;           str)
;;       (while it
;;         (ignore-errors
;;           (setq str (concat str
;;                             space
;;                             (car it))))
;;         (setq it (cdr it)
;;               space " "))
;;       str))
;;    ;; A match ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;    ((stringp thing)
;;     thing)))

(defmacro search-with-search-buffer (&rest body)
  "[internal usage]
Evaluate BODY in the search buffer."
  (declare (indent 0) (debug t))
  `(with-current-buffer (get-buffer-create search-buffer-name)
     (set-auto-mode t)
     (setq buffer-file-name (expand-file-name search-saved-file))
     ,@body))

(defun search-create-task (func async)
  "[internal usage]
Create a search object with FUNC function and ASYNC boolean."
  (list :func func
        :async async))

(defun search-task-p (task)
  "[internal usage]
Test if the TASK is a valid search object."
  (and (plist-get task :func)
       (booleanp (plist-get task :async))))

(defun search-append-task (task)
  "[internal usage]
Append TASK to `search-tasks' and evaluate it later. See `search-create-task'."
  (when (search-task-p task)
    (setq search-tasks (delq search-last search-tasks)
          search-tasks (append search-tasks (list task search-last)))))

(defun search-doer ()
  "[internal usage]
Doer decide when and what to process next."
  (let* ((task (car search-tasks))
         (func (plist-get task :func)))
    (pop search-tasks)
    ;; Execute current task.
    (condition-case err
        (and (functionp func)
             (funcall func))
      (error (message "search-doer error: %s"
                      (error-message-string err))))
    ;; Find next task.
    (if search-tasks
        (cond
         ((null (plist-get task :async))
          (search-setup-doer)))
      ;; Clean the timer if there's no task.
      (and (timerp search-timer)
           (setq search-timer (cancel-timer search-timer)))
      ;; Stop async process.
      (and (process-live-p search-proc)
           (setq search-proc (delete-process search-proc)))
      ;; Stop prmopt.
      (search-stop-prompt))))

(defun search-setup-doer ()
  "[internal usage]
Run `search-doer' after a tiny delay."
  (and (timerp search-timer)
       (cancel-timer search-timer))
  (setq search-timer (run-with-idle-timer
                      search-timer-delay nil
                      'search-doer)))

(defun search-start-dequeue ()
  "[internal usage]
Start to evaluate search task in the queue."
  (unless (timerp search-timer)
    ;; Setup timer
    (search-setup-doer)
    ;; Start prmopt.
    (search-start-prompt)))

(defvar search-prompt-animation '("-" "\\" "|" "/")
  "[internal usage]
Prompt animation.")

(defun search-default-prompt-function ()
  "[internal usage]
Default prompt function."
  (let ((char (car search-prompt-animation)))
    (minibuffer-message "Search ...%s" char)
    (setq search-prompt-animation (cdr search-prompt-animation)
          search-prompt-animation (append
                                   search-prompt-animation
                                   (list char)))))

(defun search-start-prompt ()
  "[internal usage]
Start prmopt animation."
  (unless (timerp search-prompt-timer)
    (setq search-prompt-timer
          (run-with-timer
           0 0.1
           (lambda ()
             (and (functionp search-prompt-function)
                  (funcall search-prompt-function)))))))

(defun search-stop-prompt ()
  "[internal usage]
Stop prompt animation."
  (when (timerp search-prompt-timer)
    (setq search-prompt-timer (cancel-timer search-prompt-timer)))
  (message "Search ...done"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Task API for Backends ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun search:chain (&rest tasks)
  ;; (declare (indent 0) (debug t))
  (mapc 'search-append-task tasks)
  (search-start-dequeue)
  nil)

(defun search:lambda (func)
  "Create a search object wrapping FUNC which is a lambda function."
  (search-create-task
   ;; Function.
   func
   ;; Synchronous.
   nil))

(defun search:lambda-to-search-buffer (func)
  "Create a search object wrapping FUNC under `search-buffer'."
  (search:lambda
   (eval
    `(lambda ()
       ,(and (functionp func)
             `(search-with-search-buffer
                (condition-case err
                    (save-excursion
                      (funcall ,func))
                  (error (message "search:lambda-to-search-buffer | error: %s"
                                  (error-message-string err))))
                (save-buffer)))))))

(defun search:process-shell (command bufname &optional callback)
  "Create a search object wrapping `start-process-shell-command' with COMMAND.
The output will be dumpped to a BUFNAME buffer which will be deleted when done.
The CALLBACK is evaluated under process's buffer.
See `search:process-shell-to-file' or `search:process-shell-to-search-buffer'
for example."
  (search-create-task
   ;; Function.
   (eval
    `(lambda (&rest args)
       (let* ((buf ,(if (string= bufname search-buffer-name)
                        (search-with-search-buffer
                          (current-buffer))
                      (get-buffer-create (or bufname
                                             search-temp-buffer-name)))))
         (and (process-live-p search-proc)
              (setq search-proc (delete-process search-proc)))
         (setq search-proc (start-process-shell-command
                            "*search-proc*" buf ,command))
         (set-process-sentinel
          search-proc
          (lambda (proc event)
            (with-current-buffer (process-buffer proc)
              (condition-case err
                  ,(and (functionp callback)
                        `(funcall ,callback))
                (error (message "search:process-shell | error: %s"
                                (error-message-string err))))
              ;; Kill buffer if it is a temporary buffer.
              (and (string= search-temp-buffer-name
                            (buffer-name))
                   (kill-buffer)))
            (search-setup-doer))))))
   ;; Asynchronous.
   t))

(defun search:process-shell-to-file (command filename)
  "Create a search object wrapping `start-process-shell-command' with COMMAND.
The output will be written to FILENAME file."
  (search:process-shell
    command (file-name-nondirectory filename)
    (eval `(lambda ()
             ;; Prepend the content if file is alreay existed.
             (when (file-exists-p ,filename)
               (goto-char (point-min))
               (insert-file-contents-literally))
             (setq buffer-file-name ,filename)
             (save-buffer)
             (kill-buffer)))))

(defun search:process-shell-to-search-buffer (command)
  "Create a search object wrapping `start-process-shell-command' with COMMAND.
The output will be dumpped directly to the `search-buffer'."
  (search:process-shell
    command search-buffer-name
    (lambda ()
      (setq buffer-file-name (expand-file-name search-saved-file))
      (save-buffer))))

;; !important! The last search object.
(defvar search-last (search:lambda
                     (lambda ()
                       ;; Stop prompt.
                       (search-stop-prompt)
                       ;; Reset counter.
                       (setq search-tasks-count 0)))
  "[internal usage]
The search object which always being the last one.")

;; Test >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
;; (search-test)
(defun search-test ()
  (search:chain
   (search:lambda
    (lambda ()
      (message "start")))
   (search:process-shell-to-search-buffer "ls -al")
   (search:process-shell-to-search-buffer "ls -al /bin")
   (search:process-shell-to-search-buffer "find /Users/boyw165/.emacs.d/elpa/ -name \"*.el\"|xargs grep -nH defun 2>/dev/null")
   (search:process-shell-to-file "ls -al" "/Users/boyw165/.emacs.d/test.txt")))

;; (message "%s" search-tasks)
;; (setq search-tasks nil)
;; (setq search-timer (cancel-timer search-timer))

;; (search-string "var" :dirs (expand-file-name "~/.emacs.d/oops/whereis"))
;; (search-stop)
;; <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Backends ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun search-dummy-backend (match files dirs fromfile filters)
  "Return a deferred object which doing nothing. See `search-thing'."
  )

(defun search-grep-backend (match files dirs fromfile filters)
  "Return a deferred object which doing search job with GREP. See `search-thing'."
  (eval
   `(search:chain
     ;; Prepare input file.
     ;; FILES part ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
     ,(when files
        `(search:lambda
          (lambda ()
            (with-temp-file search-temp-file
              ,(cond
                ((stringp files) `(insert ,files))
                ((listp files) `(mapc (lambda (str)
                                        (insert str "\n"))
                                      ,files)))))))
     ;; DIRS part ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
     ,@(mapcar (lambda (path)
                 `(search:process-shell-to-file
                   ;; TODO: filter
                   ,(format "find %s" (expand-file-name path))
                   search-temp-file))
               (cond
                ((stringp dirs) (list dirs))
                ((listp dirs) dirs)))
     ;; FROMFILE part ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
     ,(when fromfile
        `(search:lambda
          (lambda ()
            (with-current-buffer (find-file-noselect search-temp-file)
              (insert "\n")
              (insert-file-contents-literally ,fromfile)))))
     ;; Start to search.
     (search:process-shell-to-search-buffer
      ,(format "xargs grep -nH \"%s\" <\"%s\" 2>/dev/null"
               match
               (expand-file-name search-temp-file))))))

(defun search-ack-backend (match files dirs fromfile filters)
  "Return a deferred object which doing search job with ACK."
  )

(defun search-ag-backend (match files dirs fromfile filters)
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public API ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;###autoload
(defun search-stop ()
  (interactive)
  ;; Stop prompt.
  (search-stop-prompt)
  ;; Stop timer
  (when (timerp search-timer)
    (setq search-timer (cancel-timer search-timer)))
  ;; Stop async process.
  (when (process-live-p search-proc)
    (setq search-proc (delete-process search-proc)))
  ;; Clear tasks.
  (setq search-tasks nil
        search-tasks-count 0))

;;;###autoload
(defun search-string (match &rest args)
  "FILES format:
  (:files      (1 2 3 ...)
   :dirs       (A B C ...)
   :fromfile   FILE
   :filters    (include . exclude))"
  (interactive
   (let* ((file (buffer-file-name))
          (dir (file-name-directory file))
          (ans (ido-completing-read
                "Search file or directory? "
                `("file" "dir") nil t))
          (args (cond
                 ((string-match "^file" ans)
                  (list :files file))
                 ((string-match "^dir" ans)
                  (list :dirs dir)))))
     (push (read-from-minibuffer "Search: ") args)))
  (search-exec?)
  (when (stringp match)
    (if (< search-tasks-count search-tasks-max)
        (progn
          ;; Increase counter.
          (setq search-tasks-count (1+ search-tasks-count))
          (search:chain
           ;; Delete temp file.
           (search:lambda
            (lambda ()
              (and (file-exists-p search-temp-file)
                   (delete-file search-temp-file))))
           ;; Print opened delimiter.
           (search:lambda-to-search-buffer
            (eval
             `(lambda ()
                (goto-char (point-max))
                (insert ,(car search-delimiter) ,match "\n")))))
          ;; Delegate to `search-backends' ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
          (funcall (cdr search-backends)
                   match
                   (plist-get args :files)
                   (plist-get args :dirs)
                   (plist-get args :fromfile)
                   (plist-get args :filters))
          ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
          (search:chain
           ;; Delete intermidiate file.
           (search:lambda
            (lambda ()
              (and (file-exists-p search-temp-file)
                   (delete-file search-temp-file))))
           ;; Print closed delimiter.
           (search:lambda-to-search-buffer
            (eval
             `(lambda ()
                (goto-char (point-max))
                (insert ,(cdr search-delimiter) "\n\n")
                (save-buffer))))))
      (message
       "Search string, \"%s\", is denied due to full queue."
       match))
    search-tasks-count))

;;;###autoload
(defun search-string-command ()
  (interactive))

;;;###autoload
(defun search-toggle-search-result ()
  (interactive)
  (if (string= (buffer-name) search-buffer-name)
      ;; TODO: Kill buffer without asking.
      (progn
        (kill-buffer)
        ;; (mapc (lambda (win)
        ;;         (when (window-live-p win)
        ;;           ))
        ;;       (window-list))
        )
    (find-file search-saved-file)
    (rename-buffer search-buffer-name)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Major Mode for Search Result ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(provide 'search)
;;; search.el ends here
