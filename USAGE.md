# Usage

The sidecar reads JSON from AWS Secrets Manager and writes one file per variable at `/run/secrets/<NAME>`. That is the same path [Compose secrets](https://docs.docker.com/compose/how-tos/use-secrets/) mount. The app image does not include the AWS CLI.

Image: `ghcr.io/luxbp/aws-secrets-sidecar:2.40.1`

Compose's `secrets:` key cannot call Secrets Manager. It bind-mounts a file that already exists on the host when the container is created. This sidecar does the fetch, then writes the files Compose would have mounted. The app reads them after the sidecar exits.

## 1. Store the secret

`SecretString` is a JSON object of environment variables. Use strings, numbers, or booleans. Names must be shell identifiers. `null` values are skipped. `PATH`, `LD_PRELOAD`, and `LD_LIBRARY_PATH` are refused.

```json
{
  "API_AUTH_KEY": "…",
  "MODE": "suiteql"
}
```

A comma-separated `AWS_SECRET_ID` merges several secrets. Later secrets override earlier keys.

The sidecar writes those keys as:

```text
/run/secrets/API_AUTH_KEY
/run/secrets/MODE
```

Each file is mode `0400` and owned by `SECRETS_FILE_UID`:`SECRETS_FILE_GID` (default `1000:1000`, the Node user). File bytes match the value, with no extra newline.

## 2. Read the files from the app

Mount the volume at `/run/secrets`. On the app, set one `NAME_FILE` variable per key. This is the convention used by Docker official images (`MYSQL_PASSWORD_FILE`, `WORDPRESS_DB_PASSWORD_FILE`). The image keeps its own entrypoint.

`SECRETS_FILE_UID` and `SECRETS_FILE_GID` must match the user in the app image.

```yaml
services:
  secrets:
    image: ghcr.io/luxbp/aws-secrets-sidecar:2.40.1
    user: "0:0"
    restart: on-failure
    environment:
      AWS_REGION: us-east-1
      AWS_SECRET_ID: my/app/secret
      SECRETS_DIR: /run/secrets
      SECRETS_FILE_UID: "1000"
      SECRETS_FILE_GID: "1000"
    volumes:
      - app-secrets:/run/secrets

  app:
    image: ghcr.io/example/app:1.0.0
    restart: unless-stopped
    depends_on:
      secrets:
        condition: service_completed_successfully
    volumes:
      - app-secrets:/run/secrets:ro
    environment:
      API_AUTH_KEY_FILE: /run/secrets/API_AUTH_KEY
      MODE_FILE: /run/secrets/MODE

volumes:
  app-secrets:
```

A full copy is in [`examples/compose.yaml`](examples/compose.yaml). Drop the `127.0.0.1` bind from that file's ports when another host must reach the app.

## 3. Apps that only read environment variables

Those apps do not look at `NAME_FILE`. Copy [`embed/entrypoint.sh`](embed/entrypoint.sh) into the image. It sources `/run/secrets/app.env`, which the sidecar also writes, then runs the original command. The image needs `/bin/sh`.

```dockerfile
COPY --chmod=755 entrypoint.sh /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["your-server"]
```

Or copy it out of the published image:

```bash
id=$(docker create ghcr.io/luxbp/aws-secrets-sidecar:2.40.1)
docker cp "$id":/opt/aws-secrets-sidecar/entrypoint.sh ./entrypoint.sh
docker rm "$id"
```

If `app.env` is missing, the entrypoint leaves the environment alone. Local Compose can skip the sidecar and pass variables directly.

`SECRETS_PRESERVE` is a comma-separated list of names. A non-empty value already set on the app container wins over the file. `PORT,MODE` is the usual pair.

## Credentials

The container uses the normal AWS CLI chain: environment variables, a shared credentials file, or the instance or task role. Do not bake credentials into an image.

The role needs `secretsmanager:GetSecretValue` on the secret, and `kms:Decrypt` when the secret uses a customer-managed key. With IMDSv2, set the metadata hop limit to 2 so the container can use the instance role.

For a local run with your own AWS config, mount it on the sidecar only:

```yaml
services:
  secrets:
    volumes:
      - ${HOME}/.aws:/root/.aws:ro
      - app-secrets:/run/secrets
```

## Variables

| Variable | Where | Default | Purpose |
| --- | --- | --- | --- |
| `AWS_SECRET_ID` | sidecar | required | Secret name or ARN. Comma-separate more than one. |
| `AWS_REGION` | sidecar | `us-east-1` | Region of those secrets. |
| `SECRETS_DIR` | sidecar | `/run/secrets` | One file per variable. Set empty to skip these files. |
| `SECRETS_ENV_FILE` | both | `/run/secrets/app.env` | Shell env file for apps that need real environment variables. |
| `SECRETS_FILE_UID` | sidecar | `1000` | Owner of the files. Match the app user. |
| `SECRETS_FILE_GID` | sidecar | `1000` | Group of the files. |
| `SECRETS_PRESERVE` | app entrypoint | empty | Names whose non-empty container values win over the env file. |
