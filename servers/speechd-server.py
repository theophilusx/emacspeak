#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# $Id$
# Description: Speech Dispatcher server for Emacspeak
# Keywords: Emacspeak, Speech Dispatcher, Python
#
# LCD Archive Entry:
# emacspeak| T. V. Raman |tv.raman.tv@gmail.com
# A speech interface to Emacs |
# $Date$ |
#  $Revision$ |
# Location https://github.com/tvraman/emacspeak
#
# Copyright (C) 1995 -- 2024, T. V. Raman
# All Rights Reserved
#
# This file is not part of GNU Emacs, but the same permissions apply.
#
# GNU Emacs is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# GNU Emacs is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with GNU Emacs; see the file COPYING.  If not, write to
# the Free Software Foundation, 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

"""
Speech Dispatcher server for Emacspeak.

This server provides a pure Python implementation of an Emacspeak TTS server
that uses Speech Dispatcher as the backend. It supports voice locking via
SSML markup for different voice characteristics (pitch, rate, volume).

Requirements:
    - Python 3.7+
    - speechd Python module (usually from speech-dispatcher package)
    - sox (optional, for beep functionality)

Usage:
    python3 speechd-server.py

Or make executable and run directly:
    ./speechd-server.py
"""

import sys
import os
import re
import select
import subprocess
import threading
import time
import xml.sax.saxutils as saxutils
from collections import deque
from typing import Optional, Dict, List, Tuple, Any, Callable

# Try to import speechd
try:
    import speechd
except ImportError:
    print("Error: speechd module not found.", file=sys.stderr)
    print("Please install speech-dispatcher and its Python bindings:", file=sys.stderr)
    print("  Fedora: dnf install speech-dispatcher-python", file=sys.stderr)
    print("  Debian/Ubuntu: apt-get install python3-speechd", file=sys.stderr)
    sys.exit(1)


# =============================================================================
# TTS Library - Queue management and utilities (Python equivalent of tts-lib.tcl)
# =============================================================================

class TTSQueue:
    """Speech queue management for Emacspeak protocol."""
    
    # Event types
    SPEECH = 's'      # Speech text
    CONTROL = 'c'     # Control codes (SSML)
    BEEP = 'b'        # Beep/tone
    SOUND = 'a'       # Audio file
    RATE = 'r'        # Rate change
    
    def __init__(self):
        self.queue: deque = deque()
        self.lock = threading.Lock()
        self._head = 0
        self._tail = 0
    
    def clear(self) -> None:
        """Clear the queue."""
        with self.lock:
            self.queue.clear()
            self._head = 0
            self._tail = 0
    
    def enqueue_speech(self, text: str) -> None:
        """Queue speech text."""
        with self.lock:
            self.queue.append((self.SPEECH, text))
            self._tail += 1
    
    def enqueue_control(self, text: str) -> None:
        """Queue control codes (SSML tags)."""
        with self.lock:
            self.queue.append((self.CONTROL, text))
            self._tail += 1
    
    def enqueue_beep(self, pitch: int = 523, duration: int = 100) -> None:
        """Queue a beep."""
        with self.lock:
            self.queue.append((self.BEEP, pitch, duration))
            self._tail += 1
    
    def enqueue_sound(self, sound: str) -> None:
        """Queue a sound file."""
        with self.lock:
            self.queue.append((self.SOUND, sound))
            self._tail += 1
    
    def enqueue_rate(self, rate: int) -> None:
        """Queue a rate change."""
        with self.lock:
            self.queue.append((self.RATE, rate))
            self._tail += 1
    
    def dequeue(self) -> Optional[Tuple]:
        """Remove and return the next event from the queue."""
        with self.lock:
            if self.queue:
                self._head += 1
                return self.queue.popleft()
            return None
    
    def is_empty(self) -> bool:
        """Check if queue is empty."""
        with self.lock:
            return len(self.queue) == 0
    
    def length(self) -> int:
        """Return the number of items in queue."""
        with self.lock:
            return len(self.queue)


class TTSState:
    """TTS state management."""
    
    def __init__(self):
        # Rate settings
        self.speech_rate: int = 225
        self.char_factor: float = 1.2
        self.say_rate: int = int(self.speech_rate * self.char_factor)
        
        # Punctuation mode: 'none', 'some', 'all'
        self.punctuations: str = 'some'
        
        # Capital handling
        self.caps_beep: bool = False
        self.split_caps: bool = True
        self.allcaps_beep: bool = False
        
        # Voice characteristics for voice locking
        self.current_pitch: str = 'default'
        self.current_volume: str = 'default'
        
        # Queue state
        self.is_talking: bool = False
        self.not_stopped: bool = True
        
        # Audio player
        self.play_command: str = self._find_play_command()
        self.beep_enabled: bool = self._check_beep_support()
    
    def _find_play_command(self) -> str:
        """Find the appropriate audio player command."""
        # Check environment variable first
        if 'EMACSPEAK_PLAY' in os.environ:
            return os.environ['EMACSPEAK_PLAY']
        
        # Try paplay (PulseAudio)
        if os.path.isfile('/usr/bin/paplay'):
            return '/usr/bin/paplay'
        
        # Try aplay (ALSA)
        if os.path.isfile('/usr/bin/aplay'):
            return '/usr/bin/aplay'
        
        # Try play (SoX)
        if os.path.isfile('/usr/bin/play'):
            return '/usr/bin/play'
        
        return '/usr/bin/paplay'  # Default
    
    def _check_beep_support(self) -> bool:
        """Check if beep functionality is available."""
        return os.path.isfile('/usr/bin/sox') or os.path.isfile('/usr/bin/play')
    
    def set_speech_rate(self, rate: int) -> None:
        """Set the speech rate."""
        self.speech_rate = rate
        self.say_rate = int(rate * self.char_factor)
    
    def set_character_scale(self, factor: float) -> None:
        """Set character scale factor."""
        self.char_factor = factor
        self.say_rate = int(self.speech_rate * factor)


# =============================================================================
# SSML Utilities for Voice Locking
# =============================================================================

class SSMLBuilder:
    """Build SSML markup for voice locking support."""
    
    @staticmethod
    def escape(text: str) -> str:
        """Escape special XML characters."""
        return saxutils.escape(text)
    
    @staticmethod
    def wrap_speak(text: str) -> str:
        """Wrap text in speak tags."""
        return f'<speak>{text}</speak>'
    
    @staticmethod
    def prosody(text: str, pitch: Optional[str] = None, 
                rate: Optional[str] = None, volume: Optional[str] = None) -> str:
        """Wrap text in prosody tags for pitch/rate/volume changes."""
        attrs = []
        if pitch:
            attrs.append(f'pitch="{pitch}"')
        if rate:
            attrs.append(f'rate="{rate}"')
        if volume:
            attrs.append(f'volume="{volume}"')
        
        if attrs:
            attr_str = ' '.join(attrs)
            return f'<prosody {attr_str}>{text}</prosody>'
        return text
    
    @staticmethod
    def voice(text: str, name: Optional[str] = None, 
              variant: Optional[str] = None, lang: Optional[str] = None) -> str:
        """Wrap text in voice tags."""
        attrs = []
        if name:
            attrs.append(f'name="{name}"')
        if variant:
            attrs.append(f'variant="{variant}"')
        if lang:
            attrs.append(f'xml:lang="{lang}"')
        
        if attrs:
            attr_str = ' '.join(attrs)
            return f'<voice {attr_str}>{text}</voice>'
        return text
    
    @staticmethod
    def emphasis(text: str, level: str = 'moderate') -> str:
        """Wrap text in emphasis tags."""
        return f'<emphasis level="{level}">{text}</emphasis>'
    
    @staticmethod
    def break_tag(time_ms: Optional[int] = None, 
                  strength: Optional[str] = None) -> str:
        """Generate a break tag."""
        if time_ms:
            return f'<break time="{time_ms}ms"/>'
        elif strength:
            return f'<break strength="{strength}"/>'
        return '<break/>'
    
    @staticmethod
    def say_as(text: str, interpret_as: str, 
               format_attr: Optional[str] = None) -> str:
        """Wrap text in say-as tags."""
        if format_attr:
            return f'<say-as interpret-as="{interpret_as}" format="{format_attr}">{text}</say-as>'
        return f'<say-as interpret-as="{interpret_as}">{text}</say-as>'


# =============================================================================
# Speech Dispatcher Client
# =============================================================================

class SpeechDispatcherClient:
    """Client for Speech Dispatcher."""
    
    def __init__(self):
        self.client: Optional[speechd.SSIPClient] = None
        self.connected: bool = False
        self.current_voice: Optional[str] = None
        self.current_language: str = 'en'
    
    def connect(self, client_name: str = "emacspeak") -> bool:
        """Connect to Speech Dispatcher."""
        try:
            self.client = speechd.SSIPClient(client_name)
            self.connected = True
            
            # Set default output module
            self.client.set_output_module('default')
            
            # Note: SSML mode can cause issues with some output modules
            # We keep it disabled by default and only use SSML for voice locking
            # self.client.set_data_mode(speechd.DataMode.SSML)
            
            # Set default parameters
            self.client.set_language(self.current_language)
            self.client.set_rate(0)  # Normal rate
            self.client.set_pitch(0)  # Normal pitch
            self.client.set_volume(100)  # Full volume
            
            return True
        except Exception as e:
            print(f"Error connecting to Speech Dispatcher: {e}", file=sys.stderr)
            return False
    
    def disconnect(self) -> None:
        """Disconnect from Speech Dispatcher."""
        if self.client:
            try:
                self.client.close()
            except:
                pass
        self.connected = False
    
    def speak(self, text: str) -> None:
        """Speak text.
        
        Handles both plain text and SSML. If the text starts with <speak,
        it's treated as SSML. Otherwise, it's spoken as plain text.
        """
        if self.client and self.connected:
            try:
                # Check if this is SSML or plain text
                is_ssml = text.strip().startswith('<speak')
                
                if is_ssml:
                    # Already in SSML mode, speak directly
                    self.client.speak(text)
                else:
                    # Plain text - temporarily disable SSML if needed
                    # or just speak directly (speechd handles plain text in SSML mode)
                    self.client.speak(text)
                    
            except Exception as e:
                print(f"Error speaking: {e}", file=sys.stderr)

    def say(self, text: str) -> None:
        """Alias for speak."""
        self.speak(text)
    
    def char(self, char: str) -> None:
        """Speak a character."""
        if self.client and self.connected:
            try:
                self.client.char(char)
            except Exception as e:
                print(f"Error speaking char: {e}", file=sys.stderr)
    
    def key(self, key: str) -> None:
        """Speak a key name."""
        if self.client and self.connected:
            try:
                self.client.key(key)
            except Exception as e:
                print(f"Error speaking key: {e}", file=sys.stderr)
    
    def stop(self) -> None:
        """Stop speaking."""
        if self.client and self.connected:
            try:
                self.client.stop()
            except Exception as e:
                print(f"Error stopping: {e}", file=sys.stderr)
    
    def cancel(self) -> None:
        """Cancel all pending speech."""
        if self.client and self.connected:
            try:
                self.client.cancel()
            except Exception as e:
                print(f"Error cancelling: {e}", file=sys.stderr)
    
    def is_speaking(self) -> bool:
        """Check if currently speaking."""
        if self.client and self.connected:
            try:
                # This is a simplified check
                return False  # Speechd doesn't have a direct speaking check
            except:
                pass
        return False
    
    def set_rate(self, rate: int) -> None:
        """Set speech rate.
        
        Rate should be in range -100 to 100 where 0 is normal.
        Emacspeak uses words per minute, we need to convert.
        """
        if self.client and self.connected:
            try:
                # Convert WPM to speechd rate (-100 to 100)
                # Base rate is typically 180 WPM
                # Map 100-400 WPM to -100 to 100
                base_wpm = 180
                rate_delta = int(((rate - base_wpm) / base_wpm) * 100)
                rate_delta = max(-100, min(100, rate_delta))
                self.client.set_rate(rate_delta)
            except Exception as e:
                print(f"Error setting rate: {e}", file=sys.stderr)
    
    def set_pitch(self, pitch: int) -> None:
        """Set speech pitch (-100 to 100)."""
        if self.client and self.connected:
            try:
                self.client.set_pitch(pitch)
            except Exception as e:
                print(f"Error setting pitch: {e}", file=sys.stderr)
    
    def set_volume(self, volume: int) -> None:
        """Set speech volume (-100 to 100)."""
        if self.client and self.connected:
            try:
                self.client.set_volume(volume)
            except Exception as e:
                print(f"Error setting volume: {e}", file=sys.stderr)
    
    def set_voice(self, voice: str) -> None:
        """Set the voice."""
        if self.client and self.connected:
            try:
                self.client.set_voice(voice)
                self.current_voice = voice
            except Exception as e:
                print(f"Error setting voice: {e}", file=sys.stderr)
    
    def set_language(self, language: str) -> None:
        """Set the language."""
        if self.client and self.connected:
            try:
                self.client.set_language(language)
                self.current_language = language
            except Exception as e:
                print(f"Error setting language: {e}", file=sys.stderr)
    
    def set_punctuation_mode(self, mode: str) -> None:
        """Set punctuation mode.
        
        mode can be: 'none', 'some', 'all', 'spell'
        """
        if self.client and self.connected:
            try:
                if mode == 'none':
                    self.client.set_punctuation(speechd.PunctuationMode.NONE)
                elif mode == 'some':
                    self.client.set_punctuation(speechd.PunctuationMode.SOME)
                elif mode == 'all':
                    self.client.set_punctuation(speechd.PunctuationMode.ALL)
                elif mode == 'spell':
                    self.client.set_punctuation(speechd.PunctuationMode.SOME)
            except Exception as e:
                print(f"Error setting punctuation: {e}", file=sys.stderr)


# =============================================================================
# Emacspeak Protocol Server
# =============================================================================

class EmacspeakServer:
    """Emacspeak TTS protocol server using Speech Dispatcher."""
    
    def __init__(self):
        self.queue = TTSQueue()
        self.state = TTSState()
        self.ssml = SSMLBuilder()
        self.tts = SpeechDispatcherClient()
        self.running: bool = False
        self.debug: bool = 'DTK_DEBUG' in os.environ
        
        # Command handlers
        self.commands: Dict[str, Callable] = {
            'q': self.cmd_queue_speech,
            'c': self.cmd_queue_control,
            'd': self.cmd_dispatch,
            's': self.cmd_stop,
            't': self.cmd_tone,
            'l': self.cmd_letter,
            'sh': self.cmd_silence,
            'a': self.cmd_audio,
            'p': self.cmd_play,
            'b': self.cmd_beep,
            'r': self.cmd_rate,
            'tts_set_speech_rate': self.cmd_set_speech_rate,
            'tts_set_character_scale': self.cmd_set_character_scale,
            'tts_set_punctuations': self.cmd_set_punctuations,
            'tts_split_caps': self.cmd_split_caps,
            'tts_caps': self.cmd_caps,
            'tts_sync_state': self.cmd_sync_state,
            'tts_reset': self.cmd_reset,
            'tts_say': self.cmd_tts_say,
            'version': self.cmd_version,
        }
    
    def log(self, message: str) -> None:
        """Log debug message."""
        if self.debug:
            print(message, file=sys.stderr)
    
    def initialize(self) -> bool:
        """Initialize the server."""
        print("Speech Dispatcher server for Emacspeak", file=sys.stderr)
        print("Initializing...", file=sys.stderr)
        
        if not self.tts.connect():
            print("Failed to connect to Speech Dispatcher", file=sys.stderr)
            print("Make sure speech-dispatcher is running:", file=sys.stderr)
            print("  systemctl --user start speech-dispatcher", file=sys.stderr)
            return False
        
        # Set initial rate
        self.tts.set_rate(self.state.speech_rate)
        self.tts.set_punctuation_mode(self.state.punctuations)
        
        # Announce startup - use plain text (no SSML) for initial greeting
        try:
            self.tts.say("Speech Dispatcher server ready")
            print("Startup announcement sent", file=sys.stderr)
        except Exception as e:
            print(f"Warning: Could not send startup announcement: {e}", file=sys.stderr)
        
        print("Server initialized successfully", file=sys.stderr)
        sys.stderr.flush()
        return True
    
    def shutdown(self) -> None:
        """Shutdown the server."""
        self.tts.disconnect()
        print("Server shutdown", file=sys.stderr)
    
    # -------------------------------------------------------------------------
    # Command Handlers
    # -------------------------------------------------------------------------
    
    def cmd_queue_speech(self, text: str) -> str:
        """Queue speech text (q command)."""
        self.queue.enqueue_speech(text)
        return ""
    
    def cmd_queue_control(self, text: str) -> str:
        """Queue control codes (c command)."""
        self.queue.enqueue_control(text)
        return ""
    
    def cmd_dispatch(self, args: str = "") -> str:
        """Dispatch queued speech (d command)."""
        self.speech_task()
        return ""
    
    def cmd_stop(self, args: str = "") -> str:
        """Stop speaking (s command)."""
        if self.state.not_stopped:
            self.state.not_stopped = False
            self.tts.stop()
            self.queue.clear()
            self.state.is_talking = False
            self.state.not_stopped = True
        return ""
    
    def cmd_tone(self, pitch: str = "440", duration: str = "50") -> str:
        """Play a tone (t command)."""
        try:
            p = int(pitch)
            d = int(duration)
            if self.state.beep_enabled:
                self.queue.enqueue_beep(p, d)
                self.speech_task()
        except ValueError:
            pass
        return ""
    
    def cmd_letter(self, text: str) -> str:
        """Speak a letter/character (l command)."""
        # Clean the text
        text = text.strip()
        if text:
            # Use the char command for single characters
            if len(text) == 1:
                self.tts.char(text)
            else:
                # For multiple characters, speak as text
                self.tts.say(text)
        return ""
    
    def cmd_silence(self, duration: str = "50") -> str:
        """Insert silence (sh command)."""
        # For now, just insert a space - proper silence would need SSML
        # which we're avoiding for compatibility
        try:
            d = int(duration)
            # Enqueue a space as a placeholder for silence
            self.queue.enqueue_speech(" ")
        except ValueError:
            pass
        return ""
    
    def cmd_audio(self, sound: str) -> str:
        """Queue audio file (a command)."""
        self.queue.enqueue_sound(sound)
        return ""
    
    def cmd_play(self, sound: str) -> str:
        """Play audio file immediately (p command)."""
        self.play_sound(sound)
        self.speech_task()
        return ""
    
    def cmd_beep(self, pitch: str = "523", duration: str = "100") -> str:
        """Queue a beep (b command)."""
        try:
            p = int(pitch)
            d = int(duration)
            self.queue.enqueue_beep(p, d)
        except ValueError:
            pass
        return ""
    
    def cmd_rate(self, rate: str) -> str:
        """Queue rate change (r command)."""
        try:
            r = int(rate)
            self.queue.enqueue_rate(r)
        except ValueError:
            pass
        return ""
    
    def cmd_set_speech_rate(self, rate: str) -> str:
        """Set speech rate (tts_set_speech_rate)."""
        try:
            r = int(rate)
            self.state.set_speech_rate(r)
            self.tts.set_rate(r)
        except ValueError:
            pass
        return ""
    
    def cmd_set_character_scale(self, factor: str) -> str:
        """Set character scale (tts_set_character_scale)."""
        try:
            f = float(factor)
            self.state.set_character_scale(f)
        except ValueError:
            pass
        return ""
    
    def cmd_set_punctuations(self, mode: str) -> str:
        """Set punctuation mode (tts_set_punctuations)."""
        self.state.punctuations = mode
        self.tts.set_punctuation_mode(mode)
        return ""
    
    def cmd_split_caps(self, flag: str) -> str:
        """Set split caps mode (tts_split_caps)."""
        self.state.split_caps = (flag.lower() in ('1', 't', 'true', 'on'))
        return ""
    
    def cmd_caps(self, flag: str) -> str:
        """Set caps beep mode (tts_caps)."""
        self.state.caps_beep = (flag.lower() in ('1', 't', 'true', 'on'))
        return ""
    
    def cmd_sync_state(self, punct: str, splitcaps: str, 
                       caps: str, rate: str) -> str:
        """Sync state (tts_sync_state)."""
        self.cmd_set_punctuations(punct)
        self.cmd_split_caps(splitcaps)
        self.cmd_caps(caps)
        self.cmd_set_speech_rate(rate)
        return ""
    
    def cmd_reset(self, args: str = "") -> str:
        """Reset TTS (tts_reset)."""
        self.tts.stop()
        self.queue.clear()
        self.tts.set_rate(225)
        self.tts.set_pitch(0)
        self.tts.set_volume(100)
        self.tts.say("Resetting speech dispatcher server")
        return ""
    
    def cmd_tts_say(self, text: str) -> str:
        """Direct TTS say (tts_say)."""
        self.tts.say(text)
        return ""
    
    def cmd_version(self, args: str = "") -> str:
        """Report version."""
        version_info = "Speech Dispatcher server for Emacspeak"
        self.queue.enqueue_speech(version_info)
        self.speech_task()
        return ""
    
    # -------------------------------------------------------------------------
    # Speech Processing
    # -------------------------------------------------------------------------
    
    def play_sound(self, sound_file: str) -> None:
        """Play a sound file."""
        if os.path.isfile(sound_file):
            try:
                subprocess.Popen(
                    [self.state.play_command, sound_file],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
            except Exception as e:
                self.log(f"Error playing sound: {e}")
    
    def beep(self, freq: int = 523, duration: int = 100) -> None:
        """Generate a beep using sox."""
        if not self.state.beep_enabled:
            return
        
        try:
            length_sec = duration / 1000.0
            # Use sox to generate beep
            subprocess.Popen(
                ['play', '-q', '-n', 'synth', str(length_sec), 
                 'sin', str(freq), 'fade', 'h', '0.01', '0'],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
        except Exception as e:
            self.log(f"Error generating beep: {e}")
    
    def clean_text(self, text: str) -> str:
        """Preprocess text before speaking."""
        # Remove Emacspeak's [*] markers
        text = re.sub(r'\[\*\]', ' ', text)
        
        # Handle punctuation based on mode
        if self.state.punctuations == 'all':
            # Spell out punctuation
            text = text.replace('#', ' pound ')
            text = text.replace('*', ' star ')
            text = text.replace('@', ' at ')
            text = text.replace('&', ' ampersand ')
        
        # Handle caps
        if self.state.split_caps:
            # Add indicators for capitalized words
            # This is a simplified version
            pass
        
        return text
    
    def speech_task(self) -> None:
        """Process the speech queue."""
        self.state.is_talking = True
        
        # Collect all speech and control elements
        speech_parts = []
        has_control_codes = False
        
        while not self.queue.is_empty():
            event = self.queue.dequeue()
            if event is None:
                break
            
            event_type = event[0]
            
            if event_type == TTSQueue.SPEECH:
                text = event[1]
                cleaned = self.clean_text(text)
                # Don't escape here - we'll handle SSML wrapping later
                speech_parts.append(cleaned)
                
            elif event_type == TTSQueue.CONTROL:
                control = event[1]
                # Control codes are SSML tags or other control codes
                speech_parts.append(control)
                has_control_codes = True
                
            elif event_type == TTSQueue.BEEP:
                # Play beep immediately
                pitch, duration = event[1], event[2]
                self.beep(pitch, duration)
                
            elif event_type == TTSQueue.SOUND:
                sound = event[1]
                self.play_sound(sound)
                
            elif event_type == TTSQueue.RATE:
                rate = event[1]
                self.tts.set_rate(rate)
        
        # Speak the accumulated text
        if speech_parts:
            # Build the text
            text = ' '.join(speech_parts)
            
            # Only wrap in SSML if there are control codes (voice locking)
            # Otherwise send as plain text for better compatibility
            if has_control_codes:
                # Wrap in speak tags for SSML
                ssml_text = f'<speak>{text}</speak>'
                self.log(f"Speaking (SSML): {ssml_text[:100]}...")
                self.tts.say(ssml_text)
            else:
                # Plain text - no SSML wrapping
                self.log(f"Speaking: {text[:100]}...")
                self.tts.say(text)
        
        self.state.is_talking = False
    
    # -------------------------------------------------------------------------
    # Main Loop
    # -------------------------------------------------------------------------
    
    def process_command(self, line: str) -> None:
        """Process a single command line."""
        line = line.strip()
        if not line:
            return
        
        self.log(f"Command: {repr(line)}")
        
        # Parse command - handle both 'q text' and 'q "text"' formats
        parts = line.split(None, 1)
        cmd = parts[0] if parts else ""
        args = parts[1] if len(parts) > 1 else ""
        
        # Handle special cases
        if cmd == 'q' and not args:
            return  # Empty queue command
        
        # Look up and execute command
        handler = self.commands.get(cmd)
        if handler:
            try:
                result = handler(args)
                # Some commands need immediate response
                if cmd == 'd':
                    pass  # Dispatch already spoke
            except Exception as e:
                self.log(f"Error executing {cmd}: {e}")
                import traceback
                self.log(traceback.format_exc())
        else:
            self.log(f"Unknown command: {cmd}")
    
    def run(self) -> None:
        """Main server loop."""
        if not self.initialize():
            sys.exit(1)
        
        self.running = True
        
        # Use binary mode for stdin to avoid buffering issues
        # This is crucial for proper operation with Emacs
        stdin_fd = sys.stdin.fileno()
        
        print("Ready for commands", file=sys.stderr)
        sys.stderr.flush()
        
        # Buffer for incomplete lines
        line_buffer = b''
        
        try:
            while self.running:
                try:
                    # Use select to check for input with timeout
                    readable, _, _ = select.select([stdin_fd], [], [], 0.05)
                    
                    if readable:
                        # Read available data
                        chunk = os.read(stdin_fd, 4096)
                        if not chunk:  # EOF
                            break
                        
                        line_buffer += chunk
                        
                        # Process complete lines
                        while b'\n' in line_buffer:
                            line_end = line_buffer.find(b'\n')
                            line = line_buffer[:line_end]
                            line_buffer = line_buffer[line_end + 1:]
                            
                            try:
                                line_str = line.decode('utf-8', errors='replace')
                                self.process_command(line_str)
                            except Exception as e:
                                self.log(f"Error processing line: {e}")
                    
                    # Safety: limit buffer size
                    if len(line_buffer) > 8192:
                        line_buffer = b''
                            
                except (select.error, IOError, OSError):
                    # Interrupted system call or other IO error
                    continue
                    
        except KeyboardInterrupt:
            pass
        finally:
            self.shutdown()


def main():
    """Main entry point."""
    server = EmacspeakServer()
    server.run()


if __name__ == '__main__':
    main()

# Local variables:
# mode: python
# python-indent-offset: 4
# indent-tabs-mode: nil
# End:
