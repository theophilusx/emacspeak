;;;$Id: elint-files.el 7425 2011-11-22 01:55:17Z tv.raman.tv $  -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'advice)
(require 'derived)
(push default-directory load-path)
(load-file (expand-file-name "emacspeak-preamble.el" default-directory))
(load-file (expand-file-name "emacspeak-loaddefs.el" default-directory))
(require 'elint)
(defun batch-elint-files ()
  "Batch elint  elisp files in directory."
  (let ((file-list (directory-files default-directory nil "\\.el\\'")))
    (cl-loop
     for f in file-list do
     (unless
         (or (string-match  "emacspeak-loaddefs.el" f)
             (string-match "emacspeak-autoload.el" f)
             (string-match ".skeleton.el" f))
       (elint-file f)))))

(batch-elint-files)
