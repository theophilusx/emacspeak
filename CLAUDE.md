# AGENTS.md - Emacspeak Coding Guidelines

## Project Overview

Emacspeak is a speech interface for Emacs that enables visually impaired users to work efficiently in Emacs. It consists of:
- Emacs Lisp modules in `lisp/` (main codebase)
- TTS (Text-to-Speech) servers in `servers/` (TCL, C, Swift)
- Utilities in `utils/`
- XSL transforms in `xsl/`

## Build Commands

### Main Build
```bash
# Configure and build Emacspeak
make config
make                    # or: make emacspeak
make clean             # Clean build artifacts

# Quick rebuild (clean + config + build)
make q
```

### TTS Server Builds
```bash
# Build specific TTS servers (optional)
make espeak            # eSpeak NG server
make outloud           # IBM ViaVoice Outloud
make dtk               # Dectalk software
make swiftmac          # macOS Swift TTS (Mac only)
```

### JavaScript/Math Server
```bash
cd js/node
npm install            # Install math server dependencies
```

## Lint/Code Quality Commands

### In `lisp/` Directory
```bash
cd lisp

make lint              # Run elint on all elisp files
make elint             # Same as above
make relint            # Run relint (regex lint)
make spell             # Run codespell for typos
make indent            # Auto-indent all elisp files

# Check for long lines
make ll
```

### C Code
```bash
cd servers/<server-name>
make tidy              # Run clang-tidy (if available)
make indent            # Format C code with indent
```

### Spell Check (Root)
```bash
codespell --ignore-words=codespell.txt
```

## Testing

**Note**: Emacspeak does not have a formal test suite. Testing is manual:

1. Byte-compile code: `make` in `lisp/` directory
2. Load in Emacs: `(load-file "lisp/emacspeak-setup.el")`
3. Run with your TTS server of choice

For spell checking, the CI runs: `codespell --ignore-words=codespell.txt`

## Code Style Guidelines

### Emacs Lisp

#### File Header Template
```elisp
;;; filename.el --- Brief description -*- lexical-binding: t; -*-
;;
;; $Author: tv.raman.tv $
;; Description:  Detailed description
;; Keywords: Emacspeak, Specific, Keywords
;;;   LCD Archive entry:

;; LCD Archive Entry:
;; emacspeak| T. V. Raman |tv.raman.tv@gmail.com
;; A speech interface to Emacs |
;;
;;  $Revision: 0000 $ |
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
;; ... (GPL notice continues)

;;; Commentary:

;; Description of what this module does.

;;; Code:

;; Required modules:

(eval-when-compile (require 'cl-lib))
(cl-declaim  (optimize  (safety 0) (speed 3)))
```

#### Formatting Rules
- **Indentation**: Spaces only, no tabs (`indent-tabs-mode: nil`)
- **Fill Column**: 90 characters
- **Lexical Binding**: All files must use `lexical-binding: t`
- **Optimization**: Include `(cl-declaim (optimize (safety 0) (speed 3)))`

#### Naming Conventions
- **Public functions**: `emacspeak-<module>-<function>` (e.g., `emacspeak-speak-line`)
- **Internal helpers**: `ems--<descriptive-name>` (e.g., `ems--this-line`)
- **TTS functions**: `dtk-<function>` for speech server interface
- **Voice functions**: `<engine>-voices.el` naming
- **Variables**: Use `defconst` for constants, `defvar`/`defvar-local` for variables

#### Imports and Dependencies
- Group requires at the top of `;;; Code:` section
- Use `eval-when-compile` for compile-time requires
- Use `declare-function` for forward declarations
- Follow this order:
  1. `cl-lib` with `eval-when-compile`
  2. Optimization declaim
  3. Core requires (`emacspeak-preamble`, `dtk-speak`, etc.)
  4. `declare-function` for external functions

#### Error Handling
- Use `condition-case` for error handling
- Prefer `cl-pushnew` over `add-to-list` for performance
- Use `with-eval-after-load` for lazy loading

#### Macros and Defsubst
- Use `defsubst` for small, frequently-called functions
- Use `defmacro` with `(declare (indent N) (debug t))` for macros

### C Code (TTS Servers)

- Follow GNU C style (set via `c-file-style: "GNU"` in `.dir-locals.el`)
- Use `indent -br -brf -ce` for formatting
- Include TCL headers properly for TCL servers

### TCL Code

- Used for TTS server scripting
- Follow existing patterns in `servers/tts-lib.tcl`

## Directory Structure

```
emacspeak/
├── lisp/               # Main Emacs Lisp code
│   ├── emacspeak.el    # Main entry point
│   ├── dtk-speak.el    # TTS interface
│   ├── emacspeak-*.el  # Module-specific code
│   └── Makefile        # Build rules
├── servers/            # TTS servers
│   ├── espeak/         # eSpeak NG (TCL)
│   ├── native-espeak/  # Native eSpeak (C)
│   ├── linux-outloud/  # IBM ViaVoice (C)
│   ├── software-dtk/   # Dectalk software (C)
│   ├── mac-swiftmac/   # macOS Swift server
│   └── tts-lib.tcl     # Common TCL library
├── utils/              # Development utilities
│   ├── indent-files.el # Auto-indent elisp
│   └── elint-files.el  # Run elint
├── xsl/                # XSLT transforms
├── info/               # Documentation (Texinfo)
├── etc/                # Configuration
├── media/              # Media shortcuts
├── scapes/             # Soundscapes
└── js/node/            # Math server (Node.js)
```

## Key Files

- `lisp/emacspeak.el` - Main module, package setup
- `lisp/emacspeak-preamble.el` - Standard includes for all modules
- `lisp/dtk-speak.el` - Core TTS interface
- `lisp/emacspeak-speak.el` - Core speech functions
- `lisp/Makefile` - Build configuration
- `.dir-locals.el` - Emacs local variables (style settings)

## Development Workflow

1. **Before committing**:
   ```bash
   cd lisp && make lint spell
   ```

2. **Ensure byte-compilation succeeds**:
   ```bash
   make clean && make
   ```

3. **Check for long lines**:
   ```bash
   cd lisp && make ll
   ```

## Notes for AI Agents

- This is accessibility software - prioritize clarity and reliability
- Follow existing patterns in similar modules (e.g., `emacspeak-*.el` files)
- Always include full GPL header in new files
- Test with `make` to ensure byte-compilation succeeds
- The project targets Emacs 30.2+
- Use `require` statements carefully to avoid circular dependencies
- Many functions use advice (`defadvice`) - understand existing advice before modifying
