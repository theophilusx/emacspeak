;;; speechd-voices.el --- Define Speech Dispatcher tags  -*- lexical-binding: t; -*-
;; Description:  Module to set up Speech Dispatcher voices and personalities
;; Keywords: Voice, Personality, Speech Dispatcher
;;;   LCD Archive entry:

;; LCD Archive Entry:
;; emacspeak| T. V. Raman |tv.raman.tv@gmail.com
;; A speech interface to Emacs |
;; 
;;  $Revision: 0001 $ |
;; Location https://github.com/tvraman/emacspeak
;; 

;;;   Copyright:

;; Copyright (C) 1995 -- 2024, T. V. Raman
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

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; Commentary:

;; This module defines the various voices used in voice-lock mode by
;; the Speech Dispatcher TTS engine.
;;
;; Voice locking is implemented using SSML (Speech Synthesis Markup
;; Language) prosody tags that control pitch, pitch range, and volume.
;; These tags are sent to the Speech Dispatcher server via the 'c'
;; (control) command and wrap the speech text.
;;
;; Supported SSML tags:
;; - <prosody pitch="..."> - Controls voice pitch
;; - <prosody range="..."> - Controls pitch variation
;; - <prosody volume="..."> - Controls voice volume
;; - <emphasis level="..."> - Controls stress/emphasis

;;; Code:

;;  Required modules: 

(eval-when-compile (require 'cl-lib))
(require 'emacspeak-preamble)           ;For `ems--fastload'.
(cl-declaim  (optimize  (safety 0) (speed 3)))

;;;  Customizations:

(defcustom speechd-default-speech-rate 175
  "Default speech rate for Speech Dispatcher.
This value is in words per minute."
  :group 'tts
  :type 'integer
  :set #'(lambda(sym val)
           (set-default sym val)
           (when (string-match "speechd" dtk-program)
             (setq-default dtk-speech-rate val))))

;;;  Top-Level TTS Call

;;;###autoload
(defun speechd ()
  "Start Speech Dispatcher."
  (interactive)
  (speechd-configure-tts)
  (ems--fastload "voice-defs")
  (dtk-select-server "speechd")
  (dtk-initialize))

;;;   voice table

(defvar tts-default-voice
  'paul
  "Default voice used for Speech Dispatcher.")

(defvar speechd-default-voice-string ""
  "Default Speech Dispatcher SSML tag for default voice.")

(defvar speechd-voice-table (make-hash-table :test #'eq)
  "Association between symbols and SSML strings to set Speech Dispatcher voices.
The string can set any voice parameter using SSML prosody tags.")

(defun speechd-define-voice (name command-string)
  "Define a Speech Dispatcher voice named NAME.
This voice will be set by sending the SSML string
COMMAND-STRING to the TTS engine via the control command."
  (defvar speechd-voice-table)
  (puthash name command-string speechd-voice-table))

(defun speechd-get-voice-command (name)
  "Retrieve SSML command string for voice NAME.
If NAME is a list, concatenate the commands for each element."
  (defvar speechd-voice-table)
  (cond
   ((listp name)
    (mapconcat #'speechd-get-voice-command name " "))
   (t (or (gethash name speechd-voice-table)
          speechd-default-voice-string))))

(defun speechd-voice-defined-p (name)
  "Check if there is a voice named NAME defined."
  (defvar speechd-voice-table)
  (gethash name speechd-voice-table))

;;;  voice definitions

;; Define the default 'paul voice with no modifications
(speechd-define-voice 'paul "")

;; Alternative voice definitions using different pitch/volume combinations
(speechd-define-voice 'bold "<prosody pitch='+10%' volume='loud'>")
(speechd-define-voice 'calm "<prosody pitch='-5%' volume='soft'>")
(speechd-define-voice 'italic "<prosody pitch='+5%' range='wide'>")

;;;   Mapping CSS parameters to SSML prosody codes

;;;   Hash table for mapping families to their dimensions

(defvar speechd-css-code-tables (make-hash-table)
  "Hash table holding vectors of Speech Dispatcher SSML codes.
Keys are symbols of the form <FamilyName-Dimension>.
Values are vectors holding the SSML prosody codes for the 10 settings.")

(defun speechd-css-set-code-table (family dimension table)
  "Set up voice FAMILY.
Argument DIMENSION is the dimension being set,
and TABLE gives the values along that dimension as SSML prosody tags."
  (defvar speechd-css-code-tables)
  (let ((key (intern (format "%s-%s" family dimension))))
    (puthash key table speechd-css-code-tables)))

(defun speechd-css-get-code-table (family dimension)
  "Retrieve table of values for specified FAMILY and DIMENSION."
  (defvar speechd-css-code-tables)
  (let ((key (intern (format "%s-%s" family dimension))))
    (gethash key speechd-css-code-tables)))

;;;   Average pitch

;; Average pitch of standard voice is mapped to a setting of 5.
;; SSML pitch values are specified as percentages or labels:
;; x-low, low, medium, high, x-high
;; We use percentage values for finer control.

;;;   paul average pitch

(let ((table (make-vector 10 "")))
  (mapc
   #'(lambda (setting)
       (aset table
             (cl-first setting)
             (format "<prosody pitch=\"%s%%\">"
                     (cl-second setting))))
   '(
     (0 -30)   ; x-low
     (1 -20)
     (2 -10)   ; low
     (3 -5)
     (4 0)     ; slightly below medium
     (5 0)     ; medium/default
     (6 5)
     (7 10)    ; high
     (8 20)
     (9 30)))  ; x-high
  (speechd-css-set-code-table 'paul 'average-pitch table))

(defun speechd-get-average-pitch-code (value family)
  "Get average-pitch SSML code for specified VALUE and FAMILY."
  (or family (setq family 'paul))
  (if value
      (aref (speechd-css-get-code-table family 'average-pitch)
            value)
    ""))

;;;   Pitch range

;; Pitch range controls the variation in pitch (intonation).
;; A setting of 0 produces a monotone voice.
;; Higher values produce more animated/expressive speech.
;; SSML range is specified as a percentage.

;;;   paul pitch range

(let ((table (make-vector 10 "")))
  (mapc
   #'(lambda (setting)
       (aset table
             (cl-first setting)
             (format "<prosody range=\"%s%%\">"
                     (cl-second setting))))
   '(
     (0 0)     ; monotone
     (1 20)    ; x-low
     (2 40)
     (3 60)    ; low
     (4 80)
     (5 100)   ; medium/default
     (6 120)
     (7 140)   ; high
     (8 160)
     (9 180))) ; x-high
  (speechd-css-set-code-table 'paul 'pitch-range table))

(defun speechd-get-pitch-range-code (value family)
  "Get pitch-range SSML code for specified VALUE and FAMILY."
  (or family (setq family 'paul))
  (if value
      (aref (speechd-css-get-code-table family 'pitch-range)
            value)
    ""))

;;;   Stress

;; Stress is mapped to SSML emphasis tags.
;; However, prosody range already covers intonation variation,
;; so we use emphasis for strong stress only.

(defun speechd-get-stress-code (value _family)
  "Get stress SSML code for specified VALUE.
Stress is mapped to emphasis level."
  (cond
   ((null value) "")
   ((< value 3) "")        ; low stress - no emphasis
   ((< value 6) "<emphasis level='moderate'>")  ; moderate stress
   (t "<emphasis level='strong'>")))  ; high stress

;;;   Richness

;; Richness is implemented as a combination of volume and
;; smoothness settings in SSML. Higher richness means fuller voice.
;; We map this to volume levels.

;;;   paul richness

(let ((table (make-vector 10 "")))
  (mapc
   #'(lambda (setting)
       (aset table
             (cl-first setting)
             (format "<prosody volume=\"%s\">"
                     (cl-second setting))))
   '(
     (0 "x-soft")   ; very thin/weak
     (1 "soft")
     (2 "soft")
     (3 "medium")
     (4 "medium")
     (5 "medium")   ; default
     (6 "medium")
     (7 "loud")
     (8 "loud")
     (9 "x-loud"))) ; very full/rich
  (speechd-css-set-code-table 'paul 'richness table))

(defun speechd-get-richness-code (value family)
  "Get richness SSML code for specified VALUE and FAMILY."
  (or family (setq family 'paul))
  (if value
      (aref (speechd-css-get-code-table family 'richness)
            value)
    ""))

;;;   speechd-define-voice-from-acss

(defun speechd-define-voice-from-acss (name style)
  "Define NAME to be a Speech Dispatcher voice as specified by STYLE.
STYLE is an ACSS (Aural CSS) structure containing voice properties."
  (let* ((family (acss-family style))
         (avg-pitch (acss-average-pitch style))
         (pitch-range (acss-pitch-range style))
         (stress (acss-stress style))
         (richness (acss-richness style))
         ;; Build SSML prosody tag with all attributes
         (pitch-attr (when avg-pitch
                       (format " pitch=\"%s%%\""
                               (let ((base 0))
                                 ;; Map 0-9 scale to percentage
                                 (* (- avg-pitch 5) 6)))))
         (range-attr (when pitch-range
                       (format " range=\"%s%%\""
                               (* pitch-range 20))))
         (volume-attr (when richness
                        (format " volume=\"%s\""
                                (aref #["x-soft" "soft" "soft" "medium"
                                        "medium" "medium" "medium"
                                        "loud" "loud" "x-loud"]
                                      richness))))
         ;; Check if we need emphasis
         (emphasis (when (and stress (> stress 6))
                     "<emphasis level='strong'>"))
         ;; Build the complete SSML command
         (command
          (if (or pitch-attr range-attr volume-attr)
              (concat "<prosody"
                      (or pitch-attr "")
                      (or range-attr "")
                      (or volume-attr "")
                      ">"
                      (when emphasis emphasis))
            (when emphasis emphasis))))
    (speechd-define-voice name command)))

;;;  Configurator

(defvar speechd-character-to-speech-table nil
  "Table that records how ISO ascii characters are spoken.")

(defun speechd-setup-character-to-speech-table ()
  "Set up character pronunciation table for Speech Dispatcher."
  (when (and (null speechd-character-to-speech-table)
             (boundp 'dtk-character-to-speech-table)
             (vectorp dtk-character-to-speech-table))
    (setq speechd-character-to-speech-table
          (let ((table (cl-copy-seq dtk-character-to-speech-table)))
            (cl-loop for entry across-ref table 
                     when (string-match "\\(\\[\\*\\]\\)" entry) do
                     (setf entry (replace-match " " nil nil entry 1)))
            table))))

;;;###autoload
(defun speechd-configure-tts ()
  "Configure TTS to use Speech Dispatcher."
  (defvar tts-default-speech-rate)
  (defvar speechd-default-speech-rate)
  (defvar dtk-speaker-process)
  ;; Set up function mappings for voice handling
  (fset 'tts-voice-defined-p 'speechd-voice-defined-p)
  (fset 'tts-get-voice-command 'speechd-get-voice-command)
  (fset 'tts-define-voice-from-acss 'speechd-define-voice-from-acss)
  ;; Configure default voice and rates
  (setq tts-default-voice 'paul)
  (setq tts-default-speech-rate speechd-default-speech-rate)
  (set-default 'tts-default-speech-rate speechd-default-speech-rate)
  ;; Set rate parameters for Speech Dispatcher
  (setq dtk-speech-rate-step 25
        dtk-speech-rate-base 100
        dtk-speech-rate speechd-default-speech-rate)
  (setq-default dtk-speech-rate-step 25
                dtk-speech-rate speechd-default-speech-rate
                dtk-speech-rate-base 100)
  ;; Character scaling
  (dtk-set-character-scale 1.2 'default)
  ;; Unicode handling
  (setq dtk-handle-unicode t)
  (speechd-setup-character-to-speech-table)
  (dtk-unicode-update-untouched-charsets
   '(ascii latin-iso8859-1 latin-iso8859-15 latin-iso8859-9
           eight-bit-graphic)))

(provide 'speechd-voices)

;;; Local variables:
;;; mode: emacs-lisp
;;; lexical-binding: t
;;; End:

;;; speechd-voices.el ends here
