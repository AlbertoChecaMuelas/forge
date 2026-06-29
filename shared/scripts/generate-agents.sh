#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
MODELS_FILE="$REPO_ROOT/shared/models.yaml"
CHECK_MODE=0
TARGET="claude"
any_diff=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--target=claude|opencode|both] [--check] [-h|--help]

Generate agent markdown files from frontmatter YAML + body.md sources.

Options:
  --target=TARGET   Which set of agent files to generate (default: claude)
                      claude    - Write to agents/<role>.md using claude-frontmatter/
                      opencode  - Write to open-code/agents/<role>.md using opencode-frontmatter/
                      both      - Generate both target trees
  --check           Dry-run: compare constructed output against on-disk files.
                    Exits non-zero if any file differs.
  -h, --help        Show this help message and exit.
EOF
}

read_model() {
  local role="$1"
  local model_target="$2"

  awk -v role="$role" -v model_target="$model_target" '
    $0 ~ "^" role ":" {
      in_role = 1
      next
    }
    in_role && $0 ~ "^[^[:space:]]" {
      in_role = 0
    }
    in_role {
      pattern = "^[[:space:]]*" model_target ":[[:space:]]*"
      if ($0 ~ pattern) {
        sub(pattern, "", $0)
        print $0
        exit
      }
    }
  ' "$MODELS_FILE"
}

emit_frontmatter() {
  local frontmatter_file="$1"
  local model="$2"
  local inserted=0
  local line=""

  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    if [ "$inserted" -eq 0 ] && [[ "$line" == description:* ]]; then
      printf 'model: %s\n' "$model"
      inserted=1
    fi
  done < "$frontmatter_file"

  if [ "$inserted" -eq 0 ]; then
    printf 'model: %s\n' "$model"
  fi
}

body_path_for_role() {
  local target_name="$1"
  local role="$2"
  local opencode_body="$REPO_ROOT/open-code/agents-src/${role}.body.md"

  if [ "$target_name" = "opencode" ] && [ -f "$opencode_body" ]; then
    printf '%s\n' "$opencode_body"
    return 0
  fi

  printf '%s\n' "$REPO_ROOT/shared/agents/${role}.body.md"
}

process_role() {
  local target_name="$1"
  local role="$2"
  local frontmatter_dir output_dir model_source
  local frontmatter_file body_file output_file model tmp_file

  case "$target_name" in
    claude)
      frontmatter_dir="$REPO_ROOT/shared/scripts/claude-frontmatter"
      output_dir="$REPO_ROOT/agents"
      model_source="claude"
      ;;
    opencode)
      frontmatter_dir="$REPO_ROOT/shared/scripts/opencode-frontmatter"
      output_dir="$REPO_ROOT/open-code/agents"
      model_source="opencode"
      ;;
    *)
      echo "ERROR: unsupported target: $target_name" >&2
      exit 1
      ;;
  esac

  frontmatter_file="$frontmatter_dir/${role}.yaml"
  body_file="$(body_path_for_role "$target_name" "$role")"
  output_file="$output_dir/${role}.md"
  model="$(read_model "$role" "$model_source")"

  if [ ! -f "$frontmatter_file" ]; then
    echo "ERROR: frontmatter file not found: $frontmatter_file" >&2
    exit 1
  fi

  if [ ! -f "$body_file" ]; then
    echo "ERROR: body file not found: $body_file" >&2
    exit 1
  fi

  if [ -z "$model" ]; then
    echo "ERROR: model not found for role '$role' target '$model_source' in $MODELS_FILE" >&2
    exit 1
  fi

  if [ "$CHECK_MODE" -eq 0 ]; then
    mkdir -p "$output_dir"
  fi

  tmp_file="$(mktemp)"
  {
    printf '%s\n' '---'
    emit_frontmatter "$frontmatter_file" "$model"
    printf '%s\n' '---'
    cat "$body_file"
  } > "$tmp_file"

  if [ "$CHECK_MODE" -eq 1 ]; then
    if [ ! -f "$output_file" ]; then
      echo "MISSING: $output_file"
      any_diff=1
    elif ! cmp -s "$tmp_file" "$output_file"; then
      echo "DIFF: $output_file"
      diff "$output_file" "$tmp_file" || true
      any_diff=1
    else
      echo "OK: $output_file"
    fi
    rm -f "$tmp_file"
    return 0
  fi

  mv "$tmp_file" "$output_file"
  echo "Written: $output_file"
}

process_target() {
  local target_name="$1"
  local roles role

  case "$target_name" in
    claude)
      roles="applier tech senior tester"
      ;;
    opencode)
      roles="applier tech senior tester orchestrator"
      ;;
    *)
      echo "ERROR: unsupported target: $target_name" >&2
      exit 1
      ;;
  esac

  for role in $roles; do
    process_role "$target_name" "$role"
  done
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

if [ ! -f "$MODELS_FILE" ]; then
  echo "ERROR: models file not found: $MODELS_FILE" >&2
  exit 1
fi

case "$TARGET" in
  claude|opencode)
    process_target "$TARGET"
    ;;
  both)
    process_target claude
    process_target opencode
    ;;
  *)
    echo "ERROR: --target must be one of: claude, opencode, both" >&2
    exit 1
    ;;
esac

if [ "$CHECK_MODE" -eq 1 ] && [ "$any_diff" -eq 1 ]; then
  exit 1
fi
