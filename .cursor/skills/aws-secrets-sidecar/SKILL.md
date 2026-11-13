---
name: aws-secrets-sidecar
description: >-
  Embed ghcr.io/luxbp/aws-secrets-sidecar so a Compose app receives AWS Secrets
  Manager JSON as files under /run/secrets. Use when adding secrets to a
  container, wiring Secrets Manager into Compose, replacing a secrets
  entrypoint, or when the user mentions the aws-secrets-sidecar, GHCR sidecar,
  or NAME_FILE secrets.
---

# AWS Secrets Sidecar

Image: `ghcr.io/luxbp/aws-secrets-sidecar:2.40.1`

The sidecar fetches JSON from Secrets Manager, writes one file per variable at `/run/secrets/<NAME>`, and exits. The app image does not include the AWS CLI. Full write-up: `USAGE.md` in the aws-secrets-sidecar repo. Copy `examples/compose.yaml` from that repo rather than inventing a layout.

Compose `secrets:` cannot do this. It bind-mounts a host file at container create time and never calls Secrets Manager.

## Choose how the app reads secrets

Look at the app before editing Compose.

**The app already reads `NAME_FILE`** (Docker official-image convention, for example `MYSQL_PASSWORD_FILE`). Keep its entrypoint. Set one variable per key:

```yaml
API_AUTH_KEY_FILE: /run/secrets/API_AUTH_KEY
```

**The app reads environment variables** (`process.env`, `os.environ`, a shell). It will not see those files. Install `embed/entrypoint.sh` as the image entrypoint. It sources `/run/secrets/app.env`, then execs the command. The image needs `/bin/sh`.

```dockerfile
COPY --from=ghcr.io/luxbp/aws-secrets-sidecar:2.40.1 \
     /opt/aws-secrets-sidecar/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]
```

If the image already has an entrypoint that must still run, keep that program as the command in front of the server:

```yaml
entrypoint: ["docker-entrypoint.sh"]
command: ["original-entrypoint", "original-server"]
```

`SECRETS_PRESERVE` is a comma-separated list of names. A non-empty value already set on the app container wins over `app.env`. Use `PORT,MODE` when the stack should override those two. It does nothing unless this entrypoint is what starts the app.

If `app.env` is absent, the entrypoint leaves the environment alone. Local Compose can skip the sidecar and pass variables directly.

## Compose

```yaml
services:
  secrets:
    image: ghcr.io/luxbp/aws-secrets-sidecar:2.40.1
    user: "0:0"
    restart: on-failure
    environment:
      AWS_REGION: ${AWS_REGION:-us-east-1}
      AWS_SECRET_ID: ${AWS_SECRET_ID:?Set AWS_SECRET_ID to the Secrets Manager secret name or ARN}
      SECRETS_DIR: /run/secrets
      SECRETS_ENV_FILE: /run/secrets/app.env
      SECRETS_FILE_UID: "1000"
      SECRETS_FILE_GID: "1000"
    volumes:
      - app-secrets:/run/secrets

  app:
    depends_on:
      secrets:
        condition: service_completed_successfully
    volumes:
      - app-secrets:/run/secrets:ro

volumes:
  app-secrets:
```

Rules:

- Pin the image tag. Do not use `latest`.
- `user: "0:0"` stays. The sidecar is root so it can `chown` the files to the app user, then it exits. The app container stays its own user and mounts the volume read-only.
- `SECRETS_FILE_UID` and `SECRETS_FILE_GID` match that app user. Official Node is `1000:1000`.
- `depends_on` uses `service_completed_successfully`. The sidecar is one-shot, not a healthy long-running service.
- `restart: on-failure` on the sidecar. Do not use `unless-stopped`.
- Publish app ports on `127.0.0.1` unless another host must reach them.
- Do not bake credentials into an image. For a local AWS config, mount `${HOME}/.aws:/root/.aws:ro` on the sidecar only.

## Secret shape

`SecretString` is one JSON object of strings, numbers, and booleans. Names are shell identifiers. `null` is skipped. Objects, arrays, `PATH`, `LD_PRELOAD`, and `LD_LIBRARY_PATH` are refused. A comma-separated `AWS_SECRET_ID` merges secrets; later keys win. File bytes match the value, with no added newline.

The instance or task role needs `secretsmanager:GetSecretValue`, and `kms:Decrypt` when the secret uses a customer-managed key. With IMDSv2, set the metadata hop limit to 2.

## Changing this repo

Run `sh scripts/test.sh` after editing `load-secrets.sh`, `secret-env.jq`, or `embed/entrypoint.sh`. The tests stub the AWS CLI. Do not add a live AWS call.
