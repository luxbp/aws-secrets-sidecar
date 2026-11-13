#!/bin/sh
# Unit tests for load-secrets.sh. The aws CLI is a stub. No network calls.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required to run tests/load-secrets.test.sh\n' >&2
  exit 1
fi

bin=$work/bin
fixtures=$work/fixtures
calls=$work/calls
stdout=$work/stdout
stderr=$work/stderr
out_file=$work/secrets/app.env
file_dir=$work/run
uid=$(id -u)
gid=$(id -g)
mkdir -p "$bin" "$fixtures"

cat > "$bin/aws" << 'EOF'
#!/bin/sh
# Record `aws secretsmanager get-secret-value` and print a fixture.
set -eu
region=
id=
while [ $# -gt 0 ]; do
  case $1 in
    --region) region=$2; shift 2 ;;
    --secret-id) id=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\t%s\n' "$region" "$id" >> "$AWS_STUB_LOG"
fixture=$AWS_STUB_DIR/$id.json
if [ ! -f "$fixture" ]; then
  printf 'no fixture for %s\n' "$id" >&2
  exit 1
fi
cat "$fixture"
EOF
chmod 755 "$bin/aws"

jq_bin=$(command -v jq)
path="$bin:$(dirname "$jq_bin"):/usr/bin:/bin:/usr/sbin"

die() {
  printf 'FAIL %s: %s\n' "$case_name" "$*" >&2
  if [ -s "$stderr" ]; then
    printf 'stderr:\n' >&2
    cat "$stderr" >&2
  fi
  if [ -s "$stdout" ]; then
    printf 'stdout:\n' >&2
    cat "$stdout" >&2
  fi
  exit 1
}

perm() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%OLp' "$1"
  fi
}

owner() {
  if stat -c '%u:%g' "$1" >/dev/null 2>&1; then
    stat -c '%u:%g' "$1"
  else
    stat -f '%u:%g' "$1"
  fi
}

reset() {
  rm -rf "$fixtures" "$out_file" "$(dirname "$out_file")" "$work/run"
  mkdir -p "$fixtures"
  : > "$calls"
  : > "$stdout"
  : > "$stderr"
}

# $1 is the SecretString text (a JSON object, or whatever the test wants stored).
put_secret() {
  jq -n --arg secret_string "$2" '{SecretString:$secret_string}' > "$fixtures/$1.json"
}

# Runs the sidecar. Set secret_id, region, file_uid, and file_gid first.
# Leaves status, stdout, and stderr for the caller.
run_load() {
  set +e
  env \
    PATH="$path" \
    AWS_STUB_DIR="$fixtures" \
    AWS_STUB_LOG="$calls" \
    SECRETS_JQ_FILTER="$root/secret-env.jq" \
    SECRETS_FAIL_DELAY=0 \
    SECRETS_ENV_FILE="$out_file" \
    SECRETS_DIR="$file_dir" \
    SECRETS_FILE_UID="$file_uid" \
    SECRETS_FILE_GID="$file_gid" \
    AWS_REGION="$region" \
    AWS_SECRET_ID="$secret_id" \
    sh "$root/load-secrets.sh" >"$stdout" 2>"$stderr"
  status=$?
  set -e
}

expect_fail() {
  if [ "$status" -eq 0 ]; then
    die "expected a non-zero exit"
  fi
  if [ -f "$out_file" ]; then
    die "env file should not be written"
  fi
  if [ -d "$file_dir" ]; then
    die "secret files should not be written"
  fi
  if ! grep -q "$1" "$stderr"; then
    die "stderr missing: $1"
  fi
}

case_name=
secret_id=
region=us-east-1
file_uid=$uid
file_gid=$gid

case_name="writes one secret as a private env file"
reset
put_secret app '{"API_AUTH_KEY":"abc","N":1}'
secret_id=app
region=us-east-1
run_load
[ "$status" -eq 0 ] || die "exit $status"
[ "$(perm "$out_file")" = "400" ] || die "mode is $(perm "$out_file")"
[ "$(owner "$out_file")" = "$uid:$gid" ] || die "owner is $(owner "$out_file")"
got=$(sh -c '. "$1"; printf "%s|%s" "$API_AUTH_KEY" "$N"' sh "$out_file")
[ "$got" = "abc|1" ] || die "sourced values [$got]"
grep -q 'Read secret app' "$stdout" || die "missing read log"
grep -q "Wrote 2 environment variables to $out_file" "$stdout" || die "missing wrote log"
expected=$(printf '%s\t%s\n' us-east-1 app)
[ "$(cat "$calls")" = "$expected" ] || die "aws was not called with the region and id"
printf 'abc' > "$work/expect-key"
cmp -s "$work/expect-key" "$file_dir/API_AUTH_KEY" || die "API_AUTH_KEY file"
printf '1' > "$work/expect-n"
cmp -s "$work/expect-n" "$file_dir/N" || die "N file"
[ "$(perm "$file_dir/API_AUTH_KEY")" = "400" ] || die "secret file mode"
[ "$(owner "$file_dir/API_AUTH_KEY")" = "$uid:$gid" ] || die "secret file owner"
printf 'ok  %s\n' "$case_name"

case_name="merges secrets and lets the later one win"
reset
put_secret base '{"FOO":"old","KEEP":"yes"}'
put_secret extra '{"FOO":"new","Q":"a'\''b"}'
secret_id='base, extra'
run_load
[ "$status" -eq 0 ] || die "exit $status"
got=$(sh -c '. "$1"; printf "%s|%s|%s" "$FOO" "$KEEP" "$Q"' sh "$out_file")
[ "$got" = "new|yes|a'b" ] || die "sourced values [$got]"
printf "a'b" > "$work/expect-q"
cmp -s "$work/expect-q" "$file_dir/Q" || die "Q file"
printf 'new' > "$work/expect-foo"
cmp -s "$work/expect-foo" "$file_dir/FOO" || die "FOO file"
printf 'ok  %s\n' "$case_name"

case_name="passes AWS_REGION and skips blank ids"
reset
put_secret one '{"A":"1"}'
put_secret two '{"B":"2"}'
secret_id=' one , , two '
region=eu-west-1
run_load
[ "$status" -eq 0 ] || die "exit $status"
expected=$(printf '%s\n' 'eu-west-1	one' 'eu-west-1	two')
[ "$(cat "$calls")" = "$expected" ] || die "calls [$(cat "$calls")]"
printf 'ok  %s\n' "$case_name"

case_name="rejects a secret with no SecretString"
reset
printf '%s\n' '{}' > "$fixtures/blank.json"
secret_id=blank
run_load
expect_fail "has no SecretString"
printf 'ok  %s\n' "$case_name"

case_name="rejects a SecretString that is not a JSON object"
reset
put_secret bad '[1]'
secret_id=bad
run_load
expect_fail "must be a JSON object"
printf 'ok  %s\n' "$case_name"

case_name="rejects invalid JSON"
reset
put_secret bad 'not-json'
secret_id=bad
run_load
expect_fail "is not valid JSON"
printf 'ok  %s\n' "$case_name"

case_name="rejects an AWS CLI failure and writes nothing"
reset
secret_id=missing
run_load
expect_fail "Failed to read secret missing"
[ -s "$calls" ] || die "aws was not called"
printf 'ok  %s\n' "$case_name"

case_name="refuses PATH before writing the file"
reset
put_secret bad '{"PATH":"/tmp","OK":"1"}'
secret_id=bad
run_load
expect_fail "invalid environment variable name"
printf 'ok  %s\n' "$case_name"

case_name="rejects a bad file uid without calling AWS"
reset
secret_id=app
file_uid=abc
run_load
expect_fail "SECRETS_FILE_UID must be a non-negative integer"
[ ! -s "$calls" ] || die "aws was called"
file_uid=$uid
printf 'ok  %s\n' "$case_name"

case_name="rejects a missing secret id"
reset
secret_id=
run_load
expect_fail "AWS_SECRET_ID is required"
[ ! -s "$calls" ] || die "aws was called"
secret_id=app
printf 'ok  %s\n' "$case_name"

case_name="writes exact file bytes and drops stale keys"
reset
mkdir -p "$file_dir"
printf 'stale' > "$file_dir/GONE"
pem=$(printf 'line1\nline2')
body=$(jq -n --arg pem "$pem" '{PEM:$pem}')
put_secret app "$body"
secret_id=app
run_load
[ "$status" -eq 0 ] || die "exit $status"
printf 'line1\nline2' > "$work/expect-pem"
cmp -s "$work/expect-pem" "$file_dir/PEM" || die "PEM bytes"
[ ! -f "$file_dir/GONE" ] || die "stale key was kept"
printf 'ok  %s\n' "$case_name"

case_name="skips secret files when SECRETS_DIR is empty"
reset
file_dir=
put_secret app '{"A":"1"}'
secret_id=app
run_load
[ "$status" -eq 0 ] || die "exit $status"
[ -f "$out_file" ] || die "env file missing"
[ ! -d "$work/run" ] || die "secret dir should not be created"
file_dir=$work/run
printf 'ok  %s\n' "$case_name"

case_name="rejects a bad failure delay before doing any work"
if env SECRETS_FAIL_DELAY=no sh "$root/load-secrets.sh" >"$stdout" 2>"$stderr"; then
  die "expected a non-zero exit"
fi
grep -q 'SECRETS_FAIL_DELAY must be a non-negative integer' "$stderr" || die "missing delay message"
printf 'ok  %s\n' "$case_name"

printf 'ok  13 tests\n'
