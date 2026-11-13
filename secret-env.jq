# Merge Secrets Manager JSON objects into shell assignments.
# Input is a slurped array of objects (later objects override earlier keys).
# Invoke with: jq -s -r --arg mode render|count|files -f secret-env.jq a.json b.json

def valid_name:
  test("^[A-Za-z_][A-Za-z0-9_]*$")
  and . != "PATH"
  and . != "LD_PRELOAD"
  and . != "LD_LIBRARY_PATH";

def sh_quote:
  "'" + gsub("'"; "'\\''") + "'";

def merged:
  reduce .[] as $secret ({};
    if ($secret | type) != "object" then
      error("Secret must be a JSON object of environment variables.")
    else
      reduce ($secret | to_entries[]) as $e (.;
        if $e.value == null then
          .
        elif ($e.value | type) == "object" or ($e.value | type) == "array" then
          error("key \($e.key) must be a string, number, or boolean")
        elif ($e.key | valid_name | not) then
          error("Refusing to export invalid environment variable name: \($e.key)")
        else
          ($e.value | tostring) as $v
          | if $v | contains("\u0000") then
              error("Refusing to export \($e.key) because the value contains a NUL byte.")
            else
              .[$e.key] = $v
            end
        end
      )
    end
  )
  | if length == 0 then
      error("Secrets contained no environment variables.")
    else
      .
    end;

if $mode == "count" then
  merged | length
elif $mode == "files" then
  # One "name base64" line per variable. The shell decodes these into
  # /run/secrets/<name>, the same path Compose secrets use.
  merged
  | to_entries[]
  | "\(.key) \(.value | @base64)"
else
  merged
  | to_entries
  | map("\(.key)=\(.value | sh_quote)")
  | join("\n") + "\n"
end
