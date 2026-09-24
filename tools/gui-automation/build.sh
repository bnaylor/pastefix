#!/bin/sh
# Compiles the GUI-automation helpers into ~/.local/bin/pfx-ui (matches docs/gui-automation.md)
# and makes sure ~/.local/state/pfx-ui exists (mode 0700: it holds clipboard saves) for
# captures and clipboard saves.
set -e
out=${1:-$HOME/.local/bin/pfx-ui}
state=$HOME/.local/state/pfx-ui
mkdir -p "$out" "$state"
chmod 700 "$state"
here=$(cd "$(dirname "$0")" && pwd)
for t in pb click hold ax; do
  swiftc -O -o "$out/$t" "$here/$t.swift"
done
cp "$here/idx.py" "$out/idx.py"
echo "built: $out/{pb,click,hold,ax} and idx.py"
echo "state: $state"
