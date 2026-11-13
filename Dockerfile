# syntax=docker/dockerfile:1

# One-shot sidecar. It stays root so it can chown the env file to the app
# uid, then it exits. Do not use this image as an application base.

ARG AWS_CLI_VERSION=2.40.1
FROM amazon/aws-cli:${AWS_CLI_VERSION}

ARG AWS_CLI_VERSION
ARG IMAGE_SOURCE=https://github.com/luxbp/aws-secrets-sidecar

LABEL org.opencontainers.image.title="aws-secrets-sidecar" \
      org.opencontainers.image.description="Fetch AWS Secrets Manager JSON and write a shell env file for an application container." \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.version="${AWS_CLI_VERSION}"

USER root
WORKDIR /usr/local

# amazon/aws-cli:2.40.1 already ships jq. Install it only if a later CLI
# image drops the package.
RUN --mount=type=cache,target=/var/cache/dnf,sharing=locked \
    if ! command -v jq >/dev/null 2>&1; then \
      dnf install -y --setopt=install_weak_deps=False jq; \
    fi \
    && jq --version

COPY --link --chmod=755 load-secrets.sh /usr/local/bin/load-secrets.sh
COPY --link --chmod=644 secret-env.jq /usr/local/lib/secret-env.jq
COPY --link --chmod=755 embed/entrypoint.sh /opt/aws-secrets-sidecar/entrypoint.sh

ENV AWS_PAGER="" \
    AWS_CLI_AUTO_PROMPT=off

ENTRYPOINT ["/usr/local/bin/load-secrets.sh"]
