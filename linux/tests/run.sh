#!/usr/bin/env bash
# Тесты Ubuntu-версии. HOME подменён на временную папку: даже случайное обращение к ~ попадёт в муляж.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fake_home="$(mktemp -d)"
trap 'rm -rf "$fake_home"' EXIT
env -i PATH="/usr/bin:/bin" HOME="$fake_home" LANG=C.UTF-8 python3 -I -m unittest discover -s "$here" -p 'test_*.py' "$@"
