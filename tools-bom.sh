#!/usr/bin/env bash
# Windows PowerShell 5.1 reads BOM-less files as ANSI: Cyrillic breaks. Ensure UTF-8 BOM.
for f in "$@"; do
  if [ "$(head -c3 "$f" | od -An -tx1 | tr -d ' ')" != "efbbbf" ]; then printf '\xef\xbb\xbf' | cat - "$f" > "$f.bom" && mv "$f.bom" "$f"; fi
done
