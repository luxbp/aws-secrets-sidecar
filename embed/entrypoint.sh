#!/bin/sh
# Source the env file written by the secrets sidecar, then start the app.
# When that file is absent, keep the environment Docker already injected.
#
# SECRETS_PRESERVE is a comma-separated list of names. A non-empty value
# already set on this container wins over the same name in the file.
set -eu

env_file="${SECRETS_ENV_FILE:-/run/secrets/app.env}"

valid_name() {
  case $1 in
    [A-Za-z_]*) ;;
    *) return 1 ;;
  esac
  case $1 in
    *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

append_restore() {
  # $1 name, $2 value. Single quotes so the value is not evaluated again.
  printf "%s='" "$1" >> "$restore"
  printf '%s' "$2" | sed "s/'/'\\\\''/g" >> "$restore"
  printf "'\nexport %s\n" "$1" >> "$restore"
}

if [ -f "$env_file" ]; then
  restore=$(mktemp)
  trap 'rm -f "$restore"' EXIT

  rest=${SECRETS_PRESERVE:-}
  while [ -n "$rest" ]; do
    name=${rest%%,*}
    case $rest in
      *,*) rest=${rest#*,} ;;
      *) rest= ;;
    esac
    name=$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$name" ]; then
      continue
    fi
    if ! valid_name "$name"; then
      printf 'SECRETS_PRESERVE contains an invalid name: %s\n' "$name" >&2
      exit 1
    fi
    # The name is an identifier. The value is expanded inside the assignment,
    # so spaces and metacharacters stay data.
    eval 'value=${'"$name"'-}'
    if [ -n "$value" ]; then
      append_restore "$name" "$value"
    fi
  done

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a

  if [ -s "$restore" ]; then
    # shellcheck disable=SC1090
    . "$restore"
  fi

  rm -f "$restore"
  trap - EXIT
fi

exec "$@"
