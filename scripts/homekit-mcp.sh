#!/bin/bash
# Launch HomeKitMCP through LaunchServices and bridge stdio over named pipes.
#
# When an MCP client spawns the app binary directly as a child process,
# HMHomeManager may never report any homes and the server hangs at
# "waiting for homes to load". Starting the app with `open` makes macOS treat it
# as a regular app (with its own HomeKit permission), and the pipes connect it
# to the client's stdin/stdout.
#
# Usage in the MCP config:  "command": "/path/to/homekit-mcp.sh"
# Override the app location with HOMEKIT_MCP_APP if needed.

APP="${HOMEKIT_MCP_APP:-$HOME/Applications/HomeKitMCP.app}"
d=$(mktemp -d "${TMPDIR:-/tmp}/homekitmcp.XXXXXX")
mkfifo "$d/in" "$d/out"
cleanup() { kill "$CATIN" 2>/dev/null; rm -rf "$d"; }
trap cleanup EXIT
open -n -a "$APP" --stdin "$d/in" --stdout "$d/out" --stderr "$d/err" --args --headless || exit 1
exec 3<&0
cat <&3 > "$d/in" &
CATIN=$!
exec cat "$d/out"
