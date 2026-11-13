#!/bin/sh
# Render, quoting, and entrypoint checks. No AWS calls.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

sh "$root/tests/load-secrets.test.sh"

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required to run scripts/test.sh\n' >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'expected: [%s]\nactual:   [%s]\n' "$2" "$1" >&2
    fail "$3"
  fi
}

printf '%s\n' '{"FOO":"bar","SHARED":"old","N":1,"OK":true,"SKIP":null}' > "$tmp/a.json"
printf '%s\n' '{"SHARED":"new","Q":"a'\''b"}' > "$tmp/b.json"

rendered=$(jq -s -r --arg mode render -f "$root/secret-env.jq" "$tmp/a.json" "$tmp/b.json")
expected=$(printf "%s\n" "FOO='bar'" "SHARED='new'" "N='1'" "OK='true'" "Q='a'\\''b'")
assert_eq "$rendered" "$expected" "merged render"

count=$(jq -s -r --arg mode count -f "$root/secret-env.jq" "$tmp/a.json" "$tmp/b.json")
assert_eq "$count" "5" "merged count"

reject() {
  label=$1
  body=$2
  printf '%s\n' "$body" > "$tmp/bad.json"
  if jq -s -r --arg mode render -f "$root/secret-env.jq" "$tmp/bad.json" >"$tmp/out" 2>"$tmp/err"; then
    fail "$label should have been rejected"
  fi
}

reject "PATH" '{"PATH":"/tmp"}'
reject "nested object" '{"A":{"b":1}}'
reject "invalid name" '{"1BAD":"x"}'
reject "empty" '{"A":null}'

printf '%s\n' '{"CMD":"hello'\''$(echo pwned); '\''"}' > "$tmp/payload.json"
jq -s -r --arg mode render -f "$root/secret-env.jq" "$tmp/payload.json" > "$tmp/payload.env"
got=$(sh -c '. "$1" && printf %s "$CMD"' sh "$tmp/payload.env")
assert_eq "$got" "hello'\$(echo pwned); '" "secret values stay quoted"

# entrypoint: absent file keeps the current environment
out=$(SECRETS_ENV_FILE="$tmp/missing.env" FOO=from-env \
  sh "$root/embed/entrypoint.sh" sh -c 'printf %s "$FOO"')
assert_eq "$out" "from-env" "missing env file"

printf "%s\n" "FOO='from-file'" "PORT='111'" "MODE='from-secret'" "EVIL='\$(echo pwned)'" > "$tmp/app.env"

out=$(SECRETS_ENV_FILE="$tmp/app.env" \
  sh "$root/embed/entrypoint.sh" sh -c 'printf "%s|%s" "$FOO" "$PORT"')
assert_eq "$out" "from-file|111" "file is sourced"

out=$(SECRETS_ENV_FILE="$tmp/app.env" SECRETS_PRESERVE='PORT, MODE' \
  PORT=3000 MODE=suiteql \
  sh "$root/embed/entrypoint.sh" sh -c 'printf "%s|%s|%s" "$PORT" "$MODE" "$FOO"')
assert_eq "$out" "3000|suiteql|from-file" "preserve overrides the file"

out=$(SECRETS_ENV_FILE="$tmp/app.env" SECRETS_PRESERVE=PORT \
  PORT= \
  sh "$root/embed/entrypoint.sh" sh -c 'printf %s "$PORT"')
assert_eq "$out" "111" "empty preserve value does not override"

out=$(SECRETS_ENV_FILE="$tmp/app.env" SECRETS_PRESERVE=EVIL \
  EVIL='$(echo pwned)' \
  sh "$root/embed/entrypoint.sh" sh -c 'printf %s "$EVIL"')
assert_eq "$out" '$(echo pwned)' "preserved values are not evaluated"

nl=$(printf '3000\nX')
out=$(SECRETS_ENV_FILE="$tmp/app.env" SECRETS_PRESERVE=PORT \
  PORT="$nl" \
  sh "$root/embed/entrypoint.sh" sh -c 'printf %s "$PORT"')
assert_eq "$out" "$nl" "preserved newlines survive"

if SECRETS_ENV_FILE="$tmp/app.env" SECRETS_PRESERVE='NOT-A-NAME' \
  sh "$root/embed/entrypoint.sh" true 2>"$tmp/err"; then
  fail "invalid preserve name should fail"
fi

printf 'ok\n'
