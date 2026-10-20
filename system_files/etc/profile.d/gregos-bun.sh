#!/bin/bash
# User-level bun globals: `bun add -g <pkg>` puts binaries in ~/.bun/bin.
# The system bun/opencode binaries live in /usr/bin; a user who also installs
# their own bun with the official installer gets it from ~/.bun/bin first.
if [ -d "$HOME/.bun/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.bun/bin:"*) ;;
        *) export PATH="$HOME/.bun/bin:$PATH" ;;
    esac
fi
