#!/usr/bin/env bash
# Wrapper conservant l'interface historique mais délégant au portage Python.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PY_SCRIPT="$SCRIPT_DIR/do_rip.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 est requis pour exécuter do_rip.py" >&2
  exit 127
fi

exec python3 "$PY_SCRIPT" "$@"
