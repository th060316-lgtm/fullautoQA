#!/bin/sh
set -eu
qa_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "${QA_PYTHON:-python3}" -B "$qa_dir/CORE/runner.py" --backend auto "$@"
