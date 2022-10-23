;;; docker-utils.el --- Random utilities  -*- lexical-binding: t -*-

;; Author: Philippe Vaucher <philippe.vaucher@gmail.com>

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;;; Code:


(require 'json)
(require 'tramp)
(require 'tablist)
(require 'transient)

(defun docker-utils-get-marked-items-ids ()
  "Get the id part of `tablist-get-marked-items'."
  (mapcar #'car (tablist-get-marked-items)))

(defun docker-utils-ensure-items ()
  "Ensure at least one item is selected."
  (when (null (docker-utils-get-marked-items-ids))
    (user-error "This action cannot be used in an empty list")))

(defun docker-utils-generate-new-buffer-name (program &rest args)
  "Wrapper around `generate-new-buffer-name' using PROGRAM and ARGS."
  (generate-new-buffer-name (format "* %s %s *" program (string-join args " "))))

(defun docker-utils-generate-new-buffer (program &rest args)
  "Wrapper around `generate-new-buffer' using PROGRAM and ARGS."
  (generate-new-buffer (apply #'docker-utils-generate-new-buffer-name program args)))

(defmacro docker-utils-with-buffer (name &rest body)
  "Wrapper around `with-current-buffer'.
Execute BODY in a buffer named with the help of NAME."
  (declare (indent defun))
  `(with-current-buffer (docker-utils-generate-new-buffer "docker" ,name)
     (setq buffer-read-only nil)
     (erase-buffer)
     ,@body
     (setq buffer-read-only t)
     (goto-char (point-min))
     (pop-to-buffer (current-buffer))))

(defmacro docker-utils-transient-define-prefix (name arglist &rest args)
  "Wrapper around `transient-define-prefix' forwarding NAME, ARGLIST and ARGS and calling `docker-utils-ensure-items'."
  `(transient-define-prefix ,name ,arglist
     ,@args
     (interactive)
     (docker-utils-ensure-items)
     (transient-setup ',name)))

(defmacro docker-utils-define-transient-arguments (name)
  "Define the transient arguments function using NAME that return the latest transient value or its default."
  `(defun ,(intern (format "%s-arguments" name)) ()
     ,(format "Return the latest used arguments in the `%s' transient." name)
     (let ((history (alist-get ',name transient-history))
           (default (transient-default-value (get ',name 'transient--prefix))))
       (if (equal 0 (length history))
           (car default)
         (car history)))))

(defmacro docker-utils-refresh-entries (promise)
  "Update the current buffer with the results of PROMISE."
  `(let ((buffer (current-buffer))
         (entries ,promise))
     (with-current-buffer buffer
       (setq tabulated-list-entries entries)
       (tabulated-list-print t))))

(defvar docker-pop-to-buffer-action nil
  "Action to use internally when `docker-utils-pop-to-buffer' calls `pop-to-buffer'.")

(defun docker-utils-pop-to-buffer (name)
  "Like `pop-to-buffer', but suffix NAME with the host if on a remote host."
  (pop-to-buffer
   (if (file-remote-p default-directory)
       (with-parsed-tramp-file-name default-directory nil (concat name " - " host))
     name)
   docker-pop-to-buffer-action))

(defun docker-utils-unit-multiplier (str)
  "Return the correct multiplier for STR."
  (expt 1024 (seq-position '("B" "KB" "MB" "GB" "TB" "PB" "EB") (upcase str))))

(defun docker-utils-human-size-to-bytes (str)
  "Parse STR and return size in bytes."
  (let* ((parts (string-match "^\\([0-9\\.]+\\)\\([A-Z]+\\)?$" str))
         (value (string-to-number (match-string 1 str)))
         (multiplier (docker-utils-unit-multiplier (match-string 2 str))))
    (* value multiplier)))

(defun docker-utils-human-size-predicate (a b)
  "Sort A and B by image size."
    (< (docker-utils-human-size-to-bytes a) (docker-utils-human-size-to-bytes b)))

(defun docker-utils-columns-list-format (columns-spec)
  "Convert COLUMNS-SPEC (a list of plists) to 'tabulated-list-format', i.e. a vector of (name width sort-fn)."
  (apply 'vector
  (seq-map-indexed
   (lambda (it it-index)
     (let* ((name (plist-get it :name))
            (width (plist-get it :width))
            (sort-fn-inner (plist-get it :sort))
            (sort-fn (if sort-fn-inner
                         (let ((idx it-index))
                           (lambda (&rest args)
                             (apply sort-fn-inner
                                    (mapcar (lambda (x)
                                              (elt (cadr x) idx))
                                            args))))
                       t)))
       (list name width sort-fn)))
   columns-spec)))

(defun docker-utils-make-format-string (id-template column-spec)
  "Make the format string to pass to docker-ls commands.

ID-TEMPLATE is the Go template used to extract the property that
identifies the object (usually its id).
COLUMN-SPEC is the value of docker-X-columns."
  (let* ((templates (mapcar (lambda (it) (plist-get it :template)) column-spec))
         (delimited (string-join templates ",")))
    (format "[%s,%s]" id-template delimited)))

(defun docker-utils-parse (column-specs line)
  "Convert a LINE from \"docker ls\" to a `tabulated-list-entries' entry.

LINE is expected to be a JSON formatted array, and COLUMN-SPECS is the relevant
defcustom (e.g. `docker-image-columns`) used to apply any custom format functions."
  (condition-case nil
      (let* ((data (json-read-from-string line)))
        ;; apply format function, if any
        (seq-do-indexed
         (lambda (it it-index)
            (let ((fmt-fn (plist-get it :format))
                  (data-index (+ it-index 1)))
              (when fmt-fn (aset data data-index (apply fmt-fn (list (aref data data-index)))))))
         column-specs)
        (list (aref data 0) (seq-drop data 1)))
    (json-readtable-error
     (error "Could not read following string as json:\n%s" line))))

(defun alist-plist (alist)
  "Returns a property list containing the same keys and values as the
association list ALIST in the same order."
  (let (plist)
    (dolist (pair alist)
      (push (car pair) plist)
      (push (cdr pair) plist))
    (nreverse plist)))

(defun docker-utils-columns-setter (sym new-value)
  "Convert NEW-VALUE into a list of plists, then assign to SYM.

If NEW-VALUE already looks like a list of plists, no conversion is performed and
 NEW-VALUE is assigned to SYM unchanged.  This is expected to be used as the
value of :set in a defcustom."
  (let ((is-plist (plist-member (car new-value) :name))
        (new-value-plist (mapcar (lambda (it)
                                   (alist-plist (reverse (cl-pairlis '(:name :width :template :sort :format) it))))
                          new-value)))
    (set sym (if is-plist new-value new-value-plist))))

(defun docker-utils-columns-getter (sym)
  "Convert the value of SYM for displaying in the customization menu.

Just strips the plist symbols and returns only values.
This has no effect on the actual value of the variable."
  (--map
   (-map (-partial #'plist-get it) '(:name :width :template :sort :format))
   (symbol-value sym)))

(provide 'docker-utils)

;;; docker-utils.el ends here
