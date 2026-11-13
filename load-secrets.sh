#!/bin/sh
# Fetch JSON secrets from AWS Secrets Manager and write them for the app.
# Each variable becomes a file at /run/secrets/<name> (the Compose secrets
# path). A shell env file is also written for apps that need real environment
# variables. This process does not run the app.
set -eu

# Pause after a failed run so a log collector can read stderr. Tests set this to 0.
fail_delay=${SECRETS_FAIL_DELAY:-5}
case $fail_delay in
  ''|*[!0-9]*)
    printf '%s\n' "SECRETS_FAIL_DELAY must be a non-negative integer." >&2
    exit 1
    ;;
esac

tmp=$(mktemp -d)
trap 'status=$?; rm -rf "$tmp"; if [ "$status" -ne 0 ]; then sleep "$fail_delay"; fi; exit "$status"' EXIT

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

region=${AWS_REGION:-us-east-1}
out_file=${SECRETS_ENV_FILE:-/run/secrets/app.env}
# Empty SECRETS_DIR skips the per-key files. Unset uses the Compose path.
if [ "${SECRETS_DIR+set}" = set ]; then
  secrets_dir=$SECRETS_DIR
else
  secrets_dir=/run/secrets
fi
uid=${SECRETS_FILE_UID:-1000}
gid=${SECRETS_FILE_GID:-1000}
jq_filter=${SECRETS_JQ_FILTER:-/usr/local/lib/secret-env.jq}

case $uid in
  ''|*[!0-9]*) fail "SECRETS_FILE_UID must be a non-negative integer." ;;
esac
case $gid in
  ''|*[!0-9]*) fail "SECRETS_FILE_GID must be a non-negative integer." ;;
esac

ids=${AWS_SECRET_ID:-}
if [ -z "$ids" ]; then
  fail "AWS_SECRET_ID is required (Secrets Manager name or ARN, comma-separated for more than one)."
fi

i=0
rest=$ids
while [ -n "$rest" ]; do
  id=${rest%%,*}
  case $rest in
    *,*) rest=${rest#*,} ;;
    *) rest= ;;
  esac
  id=$(printf '%s' "$id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -z "$id" ]; then
    continue
  fi

  raw_json=$tmp/raw.json
  dest=$(printf '%s/secret-%03d.json' "$tmp" "$i")
  if ! aws secretsmanager get-secret-value \
      --region "$region" \
      --secret-id "$id" \
      --output json > "$raw_json"; then
    printf 'Failed to read secret %s\n' "$id" >&2
    exit 1
  fi
  if ! jq -e '(.SecretString | type) == "string" and .SecretString != ""' "$raw_json" >/dev/null 2>&1; then
    fail "Secret $id has no SecretString. Store a JSON object of environment variables."
  fi
  jq -r '.SecretString' "$raw_json" > "$dest"
  rm -f "$raw_json"
  if ! jq empty "$dest" >/dev/null 2>&1; then
    fail "Secret $id is not valid JSON. Expected an object of environment variables."
  fi
  if ! jq -e 'type == "object"' "$dest" >/dev/null 2>&1; then
    fail "Secret $id must be a JSON object of environment variables."
  fi
  printf 'Read secret %s\n' "$id"
  i=$((i + 1))
done

if [ "$i" -eq 0 ]; then
  fail "AWS_SECRET_ID is required (Secrets Manager name or ARN, comma-separated for more than one)."
fi

rendered=$tmp/app.env
if ! jq -s -r --arg mode render -f "$jq_filter" "$tmp"/secret-*.json > "$rendered"; then
  exit 1
fi
count=$(jq -s -r --arg mode count -f "$jq_filter" "$tmp"/secret-*.json)
if ! jq -s -r --arg mode files -f "$jq_filter" "$tmp"/secret-*.json > "$tmp/files.list"; then
  exit 1
fi

if [ -n "$secrets_dir" ]; then
  if ! command -v base64 >/dev/null 2>&1; then
    fail "base64 is required to write $secrets_dir."
  fi
  stage=$tmp/stage
  mkdir -p "$stage"
  while read -r key b64; do
    if [ -z "$key" ]; then
      continue
    fi
    if ! printf '%s' "$b64" | base64 -d > "$stage/$key"; then
      fail "Could not decode secret value for $key."
    fi
  done < "$tmp/files.list"

  mkdir -p "$secrets_dir"
  env_base=$(basename "$out_file")
  find "$secrets_dir" -mindepth 1 -maxdepth 1 -type f ! -name "$env_base" -exec rm -f {} +
  for staged in "$stage"/*; do
    if [ ! -f "$staged" ]; then
      continue
    fi
    name=$(basename "$staged")
    cp "$staged" "$secrets_dir/$name"
    chmod 0400 "$secrets_dir/$name"
    chown "${uid}:${gid}" "$secrets_dir/$name"
  done
  chown "${uid}:${gid}" "$secrets_dir"
  chmod 0700 "$secrets_dir"
  printf 'Wrote %s secret files to %s\n' "$count" "$secrets_dir"
fi

mkdir -p "$(dirname "$out_file")"
cp "$rendered" "$out_file"
chmod 0400 "$out_file"
chown "${uid}:${gid}" "$out_file"
printf 'Wrote %s environment variables to %s\n' "$count" "$out_file"
