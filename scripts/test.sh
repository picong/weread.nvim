#!/usr/bin/env sh
# Run the weread.nvim test suite from any directory.
# (可从任意目录运行测试)
set -e
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
exec nvim --headless --clean -l tests/run.lua "$@"
