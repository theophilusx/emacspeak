;;; tts-speechd.el --- Speech Dispatcher TTS Management  -*- lexical-binding: t; -*-
;; $Author: tv.raman.tv $
;; Keywords: Emacspeak, Audio Desktop, Speech Dispatcher
;;;   LCD Archive entry:

;; LCD Archive Entry:
;; emacspeak| T. V. Raman |tv.raman.tv@gmail.com
;; A speech interface to Emacs |
;; Location https://github.com/tvraman/emacspeak
;;

;;;   Copyright:

;; Copyright (C) 1995 -- 2024, T. V. Raman
;; Copyright (c) 1994, 1995 by Digital Equipment Corporation.
;; All Rights Reserved.
;;
;; This file is not part of GNU Emacs, but the same permissions apply.
;;
;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This module provides interactive commands for managing Speech Dispatcher
;; TTS settings when using the speechd server.
;;
;; Since the Emacspeak TTS protocol does not support bidirectional
;; communication, this module queries Speech Dispatcher directly via its
;; SSIP protocol over a Unix socket to retrieve available options (voices,
;; languages, output modules). Settings are applied by sending commands to
;; the running speechd server process via dtk-speaker-process.
;;
;; Available commands:
;; - tts-speechd-list-voices: Display available synthesizer voices
;; - tts-speechd-set-voice: Set synthesizer voice (with completion)
;; - tts-speechd-list-languages: Display available languages
;; - tts-speechd-set-language: Set language (with completion)
;; - tts-speechd-list-output-modules: Display available output modules
;; - tts-speechd-set-output-module: Set output module (with completion)

;;; Code:

;;   Required modules

(eval-when-compile (require 'cl-lib))
(require 'emacspeak-preamble)

;;;  Customizations

(defgroup tts-speechd nil
  "Speech Dispatcher TTS management for Emacspeak."
  :group 'tts)

(defcustom tts-speechd-connection-method 'unix-socket
  "Connection method to Speech Dispatcher for queries.
Possible values are `unix-socket' for Unix domain sockets and
`inet-socket' for Internet sockets."
  :type '(choice (const :tag "Unix domain socket" unix-socket)
                 (const :tag "Internet socket" inet-socket))
  :group 'tts-speechd)

(defcustom tts-speechd-host "localhost"
  "Host running Speech Dispatcher.
Only used when `tts-speechd-connection-method' is `inet-socket'."
  :type 'string
  :group 'tts-speechd)

(defcustom tts-speechd-port 6560
  "Port for Speech Dispatcher.
Only used when `tts-speechd-connection-method' is `inet-socket'."
  :type 'integer
  :group 'tts-speechd)

(defcustom tts-speechd-socket-name nil
  "Path to Speech Dispatcher Unix socket.
If nil, use the default socket location.
Only used when `tts-speechd-connection-method' is `unix-socket'."
  :type '(choice (const :tag "Default" nil)
                 (string :tag "Socket file"))
  :group 'tts-speechd)

(defcustom tts-speechd-timeout 3
  "Timeout in seconds for Speech Dispatcher queries."
  :type 'integer
  :group 'tts-speechd)

;;;  Internal Variables

(defvar tts-speechd--voices-cache nil
  "Cached list of available synthesizer voices.")

(defvar tts-speechd--languages-cache nil
  "Cached list of available languages.")

(defvar tts-speechd--output-modules-cache nil
  "Cached list of available output modules.")

(defconst tts-speechd--coding-system 'utf-8-dos
  "Coding system for Speech Dispatcher communication.")

;;;  SSIP Protocol Functions

(defun tts-speechd--socket-path ()
  "Return the path to Speech Dispatcher Unix socket."
  (or tts-speechd-socket-name
      (let ((runtime-dir (getenv "XDG_RUNTIME_DIR")))
        (expand-file-name
         (concat (if runtime-dir (concat runtime-dir "/") "~/.")
                 "speech-dispatcher/speechd.sock")))))

(defun tts-speechd--open-connection ()
  "Open a connection to Speech Dispatcher for queries.
Returns the process object or nil on failure."
  (condition-case err
      (let* ((buffer (generate-new-buffer " *tts-speechd-query*"))
             (process
              (cond
               ((eq tts-speechd-connection-method 'unix-socket)
                (make-network-process
                 :name "tts-speechd-query"
                 :buffer buffer
                 :family 'local
                 :service (tts-speechd--socket-path)
                 :remote (tts-speechd--socket-path)))
               ((eq tts-speechd-connection-method 'inet-socket)
                (open-network-stream
                 "tts-speechd-query" buffer
                 tts-speechd-host tts-speechd-port))
               (t (error "Invalid connection method: %s"
                         tts-speechd-connection-method)))))
        (when process
          (set-process-coding-system
           process
           tts-speechd--coding-system
           tts-speechd--coding-system)
          (set-process-query-on-exit-flag process nil))
        process)
    (error
     (message "Failed to connect to Speech Dispatcher: %s" (error-message-string err))
     nil)))

(defun tts-speechd--send-command (process command)
  "Send COMMAND to Speech Dispatcher via PROCESS.
Returns the response as a string, or nil on error."
  (condition-case err
      (let ((response ""))
        (process-send-string process (concat command "\n"))
        (with-timeout (tts-speechd-timeout
                       (error "Timeout waiting for Speech Dispatcher response"))
          ;; Wait for final response line (code followed by space, not dash)
          (while (not (string-match "^[0-9]\\{3\\} " response))
            (accept-process-output process 0.1)
            (setq response (concat response
                                   (with-current-buffer
                                       (process-buffer process)
                                     (buffer-string))))
            (with-current-buffer (process-buffer process)
              (erase-buffer))))
        response)
    (error
     (message "Error communicating with Speech Dispatcher: %s"
              (error-message-string err))
     nil)))

(defun tts-speechd--parse-list-response (response)
  "Parse a LIST response from Speech Dispatcher.
Returns a list of items, or nil if parsing fails."
  (when response
    (let ((lines (split-string response "\n" t))
          (items '()))
      (dolist (line lines)
        ;; Match lines like "249-item" (list items have code 249)
        ;; Skip the final "249 OK" line
        ;; For SYNTHESIS_VOICES, items are space-delimited: "name language variant"
        ;; We only want the first field (voice name)
        (when (string-match "^249-\\(.+\\)$" line)
          (let ((item (match-string 1 line)))
            ;; Extract first space-delimited field
            (when (string-match "^\\([^ \t]+\\)" item)
              (push (match-string 1 item) items)))))
      (nreverse items))))

(defun tts-speechd--query-list (command)
  "Query Speech Dispatcher with COMMAND and return list of results.
Returns nil on error."
  (let ((process (tts-speechd--open-connection)))
    (when process
      (let ((buffer (process-buffer process)))
        (unwind-protect
            (progn
              ;; Set client name
              (tts-speechd--send-command
               process
               (format "SET self CLIENT_NAME emacspeak:tts-query:%s"
                       (user-login-name)))
              ;; Send the actual query
              (let ((response (tts-speechd--send-command process command)))
                (tts-speechd--parse-list-response response)))
          (delete-process process)
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

;;;  Query Functions

(defun tts-speechd-get-voices (&optional refresh)
  "Get list of available synthesizer voices.
If REFRESH is non-nil, bypass cache and query Speech Dispatcher directly."
  (when (or refresh (null tts-speechd--voices-cache))
    (setq tts-speechd--voices-cache
          (tts-speechd--query-list "LIST SYNTHESIS_VOICES")))
  tts-speechd--voices-cache)

(defun tts-speechd-get-languages (&optional refresh)
  "Get list of available languages.
If REFRESH is non-nil, bypass cache and query Speech Dispatcher directly."
  (when (or refresh (null tts-speechd--languages-cache))
    (let ((raw-list (tts-speechd--query-list "LIST VOICES")))
      ;; Extract language codes from voice names (format: language-variant)
      (setq tts-speechd--languages-cache
            (delete-dups
             (mapcar (lambda (voice)
                       (if (string-match "^\\([a-z]\\{2,3\\}\\)" voice)
                           (match-string 1 voice)
                         voice))
                     raw-list)))))
  tts-speechd--languages-cache)

(defun tts-speechd-get-output-modules (&optional refresh)
  "Get list of available output modules.
If REFRESH is non-nil, bypass cache and query Speech Dispatcher directly."
  (when (or refresh (null tts-speechd--output-modules-cache))
    (setq tts-speechd--output-modules-cache
          (tts-speechd--query-list "LIST OUTPUT_MODULES")))
  tts-speechd--output-modules-cache)

;;;  TTS Server Commands

(defun tts-speechd--send-server-command (command)
  "Send COMMAND to the running speechd TTS server.
Uses dtk-speaker-process to communicate with the server."
  (defvar dtk-speaker-process)
  (unless (and (boundp 'dtk-speaker-process)
               (process-live-p dtk-speaker-process))
    (error "Speech server not running"))
  (process-send-string dtk-speaker-process (concat command "\n")))

(defun tts-speechd-set-voice-internal (voice)
  "Set synthesizer voice to VOICE.
This is the internal function that sends the command to the server."
  (tts-speechd--send-server-command (format "tts_set_voice %s" voice))
  (message "Voice set to: %s" voice))

(defun tts-speechd-set-language-internal (language)
  "Set language to LANGUAGE.
This is the internal function that sends the command to the server."
  (tts-speechd--send-server-command (format "tts_set_language %s" language))
  (message "Language set to: %s" language))

(defun tts-speechd-set-output-module-internal (module)
  "Set output module to MODULE.
This is the internal function that sends the command to the server."
  (tts-speechd--send-server-command (format "tts_set_output_module %s" module))
  (message "Output module set to: %s" module))

;;;  Interactive Commands

;;;###autoload
(defun tts-speechd-list-voices (&optional refresh)
  "Display list of available synthesizer voices.
With prefix argument REFRESH, query Speech Dispatcher directly
instead of using cached results."
  (interactive "P")
  (let ((voices (tts-speechd-get-voices refresh)))
    (if voices
        (let ((buffer (get-buffer-create "*Speech Dispatcher Voices*")))
          (with-current-buffer buffer
            (erase-buffer)
            (insert "Available Synthesizer Voices:\n\n")
            (dolist (voice voices)
              (insert (format "  %s\n" voice)))
            (goto-char (point-min)))
          (display-buffer buffer)
          (when (called-interactively-p 'interactive)
            (emacspeak-icon 'open-object)
            (dtk-speak
             (format "Found %d voices. Results in voices buffer."
                     (length voices)))))
      (message "Failed to retrieve voices from Speech Dispatcher"))))

;;;###autoload
(defun tts-speechd-set-voice (voice)
  "Set synthesizer voice to VOICE.
Prompts with completion from available voices."
  (interactive
   (list
    (let ((voices (tts-speechd-get-voices)))
      (if voices
          (completing-read "Voice: " voices nil t)
        (error "Failed to retrieve voices from Speech Dispatcher")))))
  (tts-speechd-set-voice-internal voice)
  (when (called-interactively-p 'interactive)
    (emacspeak-icon 'select-object)
    (dtk-speak (format "Voice set to %s" voice))))

;;;###autoload
(defun tts-speechd-list-languages (&optional refresh)
  "Display list of available languages.
With prefix argument REFRESH, query Speech Dispatcher directly
instead of using cached results."
  (interactive "P")
  (let ((languages (tts-speechd-get-languages refresh)))
    (if languages
        (let ((buffer (get-buffer-create "*Speech Dispatcher Languages*")))
          (with-current-buffer buffer
            (erase-buffer)
            (insert "Available Languages:\n\n")
            (dolist (lang languages)
              (insert (format "  %s\n" lang)))
            (goto-char (point-min)))
          (display-buffer buffer)
          (when (called-interactively-p 'interactive)
            (emacspeak-icon 'open-object)
            (dtk-speak
             (format "Found %d languages. Results in languages buffer."
                     (length languages)))))
      (message "Failed to retrieve languages from Speech Dispatcher"))))

;;;###autoload
(defun tts-speechd-set-language (language)
  "Set language to LANGUAGE.
Prompts with completion from available languages."
  (interactive
   (list
    (let ((languages (tts-speechd-get-languages)))
      (if languages
          (completing-read "Language: " languages nil t)
        (error "Failed to retrieve languages from Speech Dispatcher")))))
  (tts-speechd-set-language-internal language)
  (when (called-interactively-p 'interactive)
    (emacspeak-icon 'select-object)
    (dtk-speak (format "Language set to %s" language))))

;;;###autoload
(defun tts-speechd-list-output-modules (&optional refresh)
  "Display list of available output modules.
With prefix argument REFRESH, query Speech Dispatcher directly
instead of using cached results."
  (interactive "P")
  (let ((modules (tts-speechd-get-output-modules refresh)))
    (if modules
        (let ((buffer (get-buffer-create "*Speech Dispatcher Output Modules*")))
          (with-current-buffer buffer
            (erase-buffer)
            (insert "Available Output Modules:\n\n")
            (dolist (module modules)
              (insert (format "  %s\n" module)))
            (goto-char (point-min)))
          (display-buffer buffer)
          (when (called-interactively-p 'interactive)
            (emacspeak-icon 'open-object)
            (dtk-speak
             (format "Found %d output modules. Results in modules buffer."
                     (length modules)))))
      (message "Failed to retrieve output modules from Speech Dispatcher"))))

;;;###autoload
(defun tts-speechd-set-output-module (module)
  "Set output module to MODULE.
Prompts with completion from available output modules."
  (interactive
   (list
    (let ((modules (tts-speechd-get-output-modules)))
      (if modules
          (completing-read "Output module: " modules nil t)
        (error "Failed to retrieve output modules from Speech Dispatcher")))))
  (tts-speechd-set-output-module-internal module)
  (when (called-interactively-p 'interactive)
    (emacspeak-icon 'select-object)
    (dtk-speak (format "Output module set to %s" module))))

;;;###autoload
(defun tts-speechd-clear-cache ()
  "Clear cached Speech Dispatcher query results.
Use this if Speech Dispatcher configuration has changed."
  (interactive)
  (setq tts-speechd--voices-cache nil
        tts-speechd--languages-cache nil
        tts-speechd--output-modules-cache nil)
  (message "Speech Dispatcher cache cleared")
  (when (called-interactively-p 'interactive)
    (emacspeak-icon 'delete-object)
    (dtk-speak "Cache cleared")))

(provide 'tts-speechd)

;;; tts-speechd.el ends here
