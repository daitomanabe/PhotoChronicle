#!/usr/bin/env bash
set -euo pipefail

DB_PATH="${1:-plan.sqlite}"

python3 ./executor.py validate --db "$DB_PATH"
python3 ./executor.py status --db "$DB_PATH"
python3 ./executor.py run --db "$DB_PATH" --workers 2 --retry-errors --reset-running
python3 ./executor.py status --db "$DB_PATH"
