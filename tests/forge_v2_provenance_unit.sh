#!/usr/bin/env bash
# tests/forge_v2_provenance_unit.sh — sensitivity of the CRITERIA of
# provenance and of uniqueness of the versioned component.
#
# The bank of V2 certifies that the module it loads IS the file that the
# repository versions (a HARD failure, not an informative note) and that the
# versioned component is UNIQUE inside the checkout. This suite proves that
# those criteria CAN be red: it mutates COPIES of the harness, written
# OUTSIDE the repository, and observes that the expected control goes red
# while it was green on the pristine harness.
#
# The repository is NEVER modified by this suite.
#
# Usage:
#   bash tests/forge_v2_provenance_unit.sh
#
# Environment:
#   FORGE_V2_PROVENANCE_WORKDIR    parent of the temporary directory of the
#                                  suite (default: the temporary directory of
#                                  the process).
#   FORGE_V2_PROVENANCE_EVIDENCE   file of the evidence (JSON).
#
# Exit codes:
#   0  every control is green and every mutation is detected
#   1  a control is red or a mutation was not detected
#   2  the harness could not be read or the criterion could not be extracted
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MUTATION_SUITE="$SCRIPT_DIR/forge_v2_provenance_mutation.py"

if [ ! -f "$MUTATION_SUITE" ]; then
  echo "FALLO: no existe la suite de mutaciones: $MUTATION_SUITE" >&2
  exit 2
fi

if [ ! -f "$REPO_ROOT/tests/forge_v2_safety_harness.py" ]; then
  echo "FALLO: no existe el arnes del banco: $REPO_ROOT/tests/forge_v2_safety_harness.py" >&2
  exit 2
fi

exec python3 "$MUTATION_SUITE"
