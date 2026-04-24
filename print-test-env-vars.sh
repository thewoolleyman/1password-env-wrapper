#!/usr/bin/env bash
set -Eeuo pipefail

# Print every exported environment variable whose name starts with TEST_,
# one per line, in NAME=value form, sorted by name. Exits 0 even when no
# matching variable is set.

while IFS= read -r name; do
  printf '%s=%s\n' "$name" "${!name}"
done < <(compgen -e | { grep '^TEST_' || true; } | LC_ALL=C sort)
