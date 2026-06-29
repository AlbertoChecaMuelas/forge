#!/usr/bin/env sh

load_forge_token() {
  key="$1"
  token_file="${HOME}/.opencode-tokens"

  eval "current_value=\${$key-}"
  if [ -n "${current_value}" ]; then
    export "$key"
    return 0
  fi

  if [ ! -f "$token_file" ]; then
    return 0
  fi

  file_value=$(grep "^${key}=" "$token_file" 2>/dev/null | tail -n 1 | sed "s/^${key}=//") || true
  if [ -z "$file_value" ]; then
    return 0
  fi

  case "$file_value" in
    \"*\") file_value=$(printf '%s' "$file_value" | sed 's/^"//; s/"$//') ;;
    \'*\') file_value=$(printf '%s' "$file_value" | sed "s/^'//; s/'$//") ;;
  esac

  eval "$key=\$file_value"
  export "$key"
}

load_forge_token ANTHROPIC_API_KEY
load_forge_token OPENAI_API_KEY
load_forge_token OPENROUTER_API_KEY
load_forge_token MINIMAX_API_KEY
