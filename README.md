# AWS Secrets Sidecar

One-shot container that reads JSON from AWS Secrets Manager and writes one file per variable at `/run/secrets/<NAME>`, the path [Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/) use. The application image does not include the AWS CLI.

This is the sidecar from `lbppro-dataapp`, packaged on its own so any Compose stack can pull it from GHCR.

## How it fits together

1. This container runs as root, fetches one or more secrets, and writes `/run/secrets/<NAME>` mode `0400`, owned by `SECRETS_FILE_UID`:`SECRETS_FILE_GID` (default `1000:1000`, the official Node image user). It also writes `/run/secrets/app.env` for apps that need real environment variables.
2. It exits 0. Compose starts the app only after that (`service_completed_successfully`).
3. An app that follows the Docker `NAME_FILE` convention reads `/run/secrets/<NAME>` with its own entrypoint. Other apps source `app.env` first.

Each secret's `SecretString` is a JSON object of environment variables:

```json
{
  "API_AUTH_KEY": "…",
  "MODE": "suiteql"
}
```

A comma-separated `AWS_SECRET_ID` merges several secrets. Later secrets override earlier keys. `null` values are skipped. Values must be strings, numbers, or booleans. Names must be shell identifiers. `PATH`, `LD_PRELOAD`, and `LD_LIBRARY_PATH` are refused, and values are single-quoted so they cannot break out of the env file.

## Use it in a stack

Copy [`examples/compose.yaml`](examples/compose.yaml). Set `AWS_SECRET_ID` and point `APP_IMAGE` at your application.

The instance or task role needs `secretsmanager:GetSecretValue` on the secret, and `kms:Decrypt` when the secret uses a customer-managed key. With IMDSv2, set the metadata hop limit to **2** so the container can use the instance role.

Credentials follow the AWS CLI chain: environment variables, a mounted shared credentials file, or the instance or task role. Do not bake credentials into an image. For a local run against your own AWS config:

```yaml
services:
  secrets:
    volumes:
      - ${HOME}/.aws:/root/.aws:ro
```

## App image

Images that already understand `NAME_FILE` (the convention in the Compose secrets guide) do not need a new entrypoint. Set `API_AUTH_KEY_FILE=/run/secrets/API_AUTH_KEY` and mount the volume at `/run/secrets`. See [USAGE.md](USAGE.md).

For an app that only reads environment variables, copy [`embed/entrypoint.sh`](embed/entrypoint.sh) into the image and set it as the entrypoint. The image needs `/bin/sh`.

```dockerfile
COPY --chmod=755 entrypoint.sh /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["your-server"]
```

You can also copy it out of a published image:

```bash
id=$(docker create ghcr.io/luxbp/aws-secrets-sidecar:2.40.1)
docker cp "$id":/opt/aws-secrets-sidecar/entrypoint.sh ./entrypoint.sh
docker rm "$id"
```

`SECRETS_PRESERVE` is a comma-separated list of names. When one of those is already set to a non-empty value on the app container, that value wins over the secret file. `lbppro-dataapp` uses `PORT,MODE`.

When `/run/secrets/app.env` is absent, the entrypoint leaves the environment alone. Local Compose can keep passing variables directly and skip the sidecar.

## Configuration

| Variable | Where | Default | Purpose |
| --- | --- | --- | --- |
| `AWS_SECRET_ID` | sidecar | required | Secret name or ARN. Comma-separate more than one. |
| `AWS_REGION` | sidecar | `us-east-1` | Region of those secrets. |
| `SECRETS_DIR` | sidecar | `/run/secrets` | Directory of one file per variable. Empty skips these files. |
| `SECRETS_ENV_FILE` | both | `/run/secrets/app.env` | Shell env file for apps that need real environment variables. |
| `SECRETS_FILE_UID` | sidecar | `1000` | Owner of the env file. Match the app user. |
| `SECRETS_FILE_GID` | sidecar | `1000` | Group of the env file. |
| `SECRETS_PRESERVE` | app | empty | Names whose non-empty container values win over the file. |
| `SECRETS_JQ_FILTER` | sidecar | `/usr/local/lib/secret-env.jq` | jq program that renders the env file. |
| `SECRETS_FAIL_DELAY` | sidecar | `5` | Seconds to pause after a failed run so logs can be collected. |

The sidecar also honors the normal AWS CLI variables (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, `AWS_WEB_IDENTITY_TOKEN_FILE`, and so on).

## Build and publish

[`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml) tests the renderer, then builds `linux/amd64` and `linux/arm64` and pushes to `ghcr.io/<owner>/<repo>` on pushes to `main` and on `v*` tags.

Tags: `latest` and `2.40.1` (the pinned AWS CLI version) on the default branch, plus the branch name, `sha-<short>`, and semver tags (`1.2.3`, `1.2`, `1`) when you push `vX.Y.Z`.

After the first push, open the package on GitHub and grant pull access to the repositories that use the image, or change the package visibility. A private repository publishes a private package.

Change the owner in `examples/compose.yaml` if the GitHub repository is not `luxbp/aws-secrets-sidecar`.

Local checks:

```bash
docker compose build
sh scripts/test.sh
AWS_SECRET_ID=my/secret AWS_REGION=us-east-1 docker compose run --rm secrets
```

`scripts/test.sh` runs the renderer checks and `tests/load-secrets.test.sh`. It needs `jq` on the host. The unit test stubs the AWS CLI, so nothing calls AWS. A failed sidecar run pauses for `SECRETS_FAIL_DELAY` seconds (default 5); the unit test sets that to 0.

## Why the image runs as root

It writes a `0400` file and `chown`s it to the app user, then exits. A non-root user cannot `chown` to an arbitrary uid. Keep the application container on its own user and mount the volume read-only there. The AWS CLI base image is large because it is `amazon/aws-cli`, which is the client this sidecar uses to call Secrets Manager.
