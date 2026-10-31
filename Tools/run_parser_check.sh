#!/bin/sh
# Usage: Tools/run_parser_check.sh file.fit [more.fit ...]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ParserCheck"
swiftc -swift-version 6 "$ROOT/FitSync/FITParser.swift" "$ROOT/Tools/ParserCheck/main.swift" -o "$OUT"
for f in "$@"; do echo "== $f"; "$OUT" "$f" || true; done
