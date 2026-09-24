#!/bin/sh
# Terminal launcher with diagnostics. --diagnose checks the system without starting Roblox.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "${1:-}" in
    --diagnose|--debug) exec "$HERE/RobloxLinux.AppImage" "$@";;
    *) exec "$HERE/RobloxLinux.AppImage" --debug "$@";;
esac
