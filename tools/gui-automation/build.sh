#!/bin/sh
# Compiles the GUI-automation helpers into /tmp/pfx-ui (git-ignored scratch, matches docs/gui-automation.md).
set -e
out=${1:-/tmp/pfx-ui}
mkdir -p "$out"
here=$(cd "$(dirname "$0")" && pwd)
for t in pb click hold ax; do
  swiftc -O -o "$out/$t" "$here/$t.swift"
done
cp "$here/idx.py" "$out/idx.py"
echo "built: $out/{pb,click,hold,ax} and idx.py"
