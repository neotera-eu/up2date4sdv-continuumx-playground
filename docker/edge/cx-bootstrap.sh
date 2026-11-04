#!/bin/bash
# Edge bootstrap entrypoint. Runs numbered steps in order (00, 01, ...).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== edge bootstrap start ==="
for step in "$DIR"/cx-bootstrap-[0-9][0-9]-*.sh; do
  [[ -f "$step" ]] || continue
  echo "==> $(basename "$step")"
  source "$step"
done
echo "=== edge bootstrap done ==="
