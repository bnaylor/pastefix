#!/bin/sh
# pastefix: name = BigErr
i=0
while [ $i -lt 5000 ]; do
  echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >&2
  i=$((i + 1))
done
exit 3
