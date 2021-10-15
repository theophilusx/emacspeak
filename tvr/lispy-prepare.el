(define-key emacs-lisp-mode-map (ems-kbd "C-c e") 'macrostep-expand)
(defun conditionally-enable-lispy ()
  (when (memq this-command '(eval-expression emacspeak-wizards-show-eval-result))
    (lispy-mode 1)))
(with-eval-after-load "lispy"
  (cl-declare (special lispy-mode-map lispy-mode-map-lispy))
  (define-key lispy-mode-map (ems-kbd "C-,") nil)
  (define-key lispy-mode-map-lispy (ems-kbd "C-,") nil)
  (define-key lispy-mode-map "\M-m" nil)
  (define-key lispy-mode-map "\C-y" 'emacspeak-muggles-yank-pop/yank)
  (define-key lispy-mode-map ";" 'self-insert-command)
  (define-key lispy-mode-map ":" 'self-insert-command)
  (define-key lispy-mode-map "\M-;" 'lispy-comment)
  (define-key lispy-mode-map "\C-d" 'delete-char)
  (define-key lispy-mode-map "\M-\C-d" 'lispy-delete)
  (define-key lispy-mode-map "\M-d" 'kill-word)
  (define-key lispy-mode-map "a" 'special-lispy-beginning-of-defun)
;;; lispy in ielm
  (add-hook 'ielm-mode-hook 'lispy-mode)
;;;  Lispy for eval-expression:
  (add-hook 'minibuffer-setup-hook 'conditionally-enable-lispy))
