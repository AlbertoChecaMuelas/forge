#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

ROLES="applier tech senior tester"
CHECK_MODE=0
TARGET="claude"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--target=claude] [--check] [-h|--help]

Generate agent markdown files from frontmatter YAML + body.md sources.

Options:
  --target=TARGET   Which set of agent files to generate (default: claude)
                      claude    - Write to agents/<role>.md using claude-frontmatter/
  --check           Dry-run: compare constructed output against on-disk files.
                    Exits non-zero if any file differs.
  -h, --help        Show this help message and exit.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --check)
      CHECK_MODE=1
      ;;
    --target=*)
      TARGET="${arg#--target=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$TARGET" != "claude" ]]; then
  echo "ERROR: --target must be: claude" >&2
  exit 1
fi

any_diff=0

process_target() {
  local frontmatter_dir="$REPO_ROOT/shared/scripts/claude-frontmatter"
  local output_dir="$REPO_ROOT/agents"

  for role in $ROLES; do
    frontmatter_file="$frontmatter_dir/${role}.yaml"
    body_file="$REPO_ROOT/shared/agents/${role}.body.md"
    output_file="$output_dir/${role}.md"

    if [ ! -f "$frontmatter_file" ]; then
      echo "ERROR: frontmatter file not found: $frontmatter_file" >&2
      exit 1
    fi

    if [ ! -f "$body_file" ]; then
      echo "ERROR: body file not found: $body_file" >&2
      exit 1
    fi

    # Construct the content: ---\n<frontmatter>\n---\n<body>
    # Note: bash command substitution strips trailing newlines, so we explicitly add \n after
    # the frontmatter field. The body file starts with \n which provides the blank separator line.
    constructed=$(printf '%s\n%s\n%s\n%s' "---" "$(cat "$frontmatter_file")" "---" "$(cat "$body_file")")

    if [ "$CHECK_MODE" -eq 1 ]; then
      if [ ! -f "$output_file" ]; then
        echo "MISSING: $output_file"
        any_diff=1
      else
        existing=$(cat "$output_file")
        if [ "$constructed" != "$existing" ]; then
          echo "DIFF: $output_file"
          diff <(printf '%s\n' "$existing") <(printf '%s\n' "$constructed") || true
          any_diff=1
        else
          echo "OK: $output_file"
        fi
      fi
    else
      printf '%s\n' "$constructed" > "$output_file"
      echo "Written: $output_file"
    fi
  done
}

process_target

if [ "$CHECK_MODE" -eq 1 ] && [ "$any_diff" -eq 1 ]; then
  exit 1
fi
