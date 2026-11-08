# Liaison single-container image for Northflank (draft, not yet pushed to a fork)
#
# Why this file exists: the repo has no root Dockerfile, and the official
# deploy/docker setup is 3 containers with host networking (443 + 30012 +
# guacd on 4822) plus pre-built artifacts from `make package`. Northflank's
# combined service is one container behind an ingress, so this Dockerfile
# builds everything from source in multi-stage builds and runs liaison +
# frontier together in one container.
#
# v1 scope (deliberate):
# - Web console: plain HTTP on $MANAGER_PORT (default 8080). Northflank
#   terminates TLS at the ingress, so manager TLS is disabled in the
#   Northflank config template. Frontier still uses its own TLS on 30012.
# - guacd is NOT included: WebDesktop (RDP/VNC) will not work in v1.
#   SSH/SFTP, databases, files, LLM gateway and Edge connectors do not
#   need guacd.
# - Edge packages: only linux-amd64 is built in v1 (Northflank runs amd64).
#   Other platforms will be missing from the console's edge download list.
# - Data: SQLite lives in /opt/liaison/data — mount the Northflank volume
#   there. Certs/logs under /opt/liaison are ephemeral; the self-signed
#   cert is regenerated on first boot and only secures liaison<->frontier.

# ---------- stage 1: web frontend ----------
FROM node:20-bookworm-slim AS web
WORKDIR /src/web
COPY web/package.json web/pnpm-lock.yaml ./
RUN corepack enable && corepack prepare pnpm@10.28.1 --activate \
    && pnpm install --frozen-lockfile
COPY web/ ./
RUN pnpm build

# ---------- stage 2: Go binaries + frontier ----------
FROM golang:1.26-bookworm AS go-build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc libsqlite3-dev curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=1 go build -trimpath -ldflags "-s -w" \
        -o /out/liaison ./cmd/manager/main.go \
    && CGO_ENABLED=1 go build -trimpath -ldflags "-s -w" \
        -o /out/password-generator ./tools/password-generator \
    && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
        -o /out/liaison-edge ./cmd/edge/main.go
# frontier is a prebuilt upstream binary (same source as Makefile's
# build-frontier-linux target: singchia/frontier v1.2.4, linux-amd64).
RUN curl -fsSL -o /out/frontier \
        https://github.com/singchia/frontier/releases/download/v1.2.4/frontier-linux-amd64 \
    && chmod +x /out/frontier \
    && file /out/frontier | grep -q 'ELF 64-bit.*x86-64'

# ---------- stage 3: runtime ----------
FROM --platform=linux/amd64 debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates openssl sqlite3 bash tzdata gettext-base libcap2-bin \
    && rm -rf /var/lib/apt/lists/*
RUN groupadd -g 1000 liaison && useradd -u 1000 -g 1000 -m -d /opt/liaison -s /bin/bash liaison
RUN mkdir -p /opt/liaison/bin /opt/liaison/conf /opt/liaison/data \
        /opt/liaison/logs /opt/liaison/certs /opt/liaison/web /opt/liaison/edge \
    && chown -R liaison:liaison /opt/liaison

COPY --from=go-build --chown=liaison:liaison /out/liaison /opt/liaison/bin/liaison
COPY --from=go-build --chown=liaison:liaison /out/password-generator /opt/liaison/bin/password-generator
COPY --from=go-build --chown=liaison:liaison /out/frontier /opt/liaison/bin/frontier
COPY --from=web --chown=liaison:liaison /src/web/dist/ /opt/liaison/web/

# Edge packages for the console download list (v1: linux-amd64 only).
COPY --chown=liaison:liaison dist/edge/ /opt/liaison/edge/
COPY --from=go-build --chown=liaison:liaison /out/liaison-edge /tmp/edge-pkg/liaison-edge
COPY dist/edge/liaison-edge.yaml.template /tmp/edge-pkg/liaison-edge.yaml.template
RUN tar -czf /opt/liaison/edge/liaison-edge-linux-amd64.tar.gz -C /tmp/edge-pkg liaison-edge liaison-edge.yaml.template \
    && chown liaison:liaison /opt/liaison/edge/liaison-edge-linux-amd64.tar.gz \
    && rm -rf /tmp/edge-pkg

COPY deploy/docker/entrypoint-liaison.sh /usr/local/bin/entrypoint-liaison.sh
COPY deploy/docker/entrypoint-frontier.sh /usr/local/bin/entrypoint-frontier.sh
COPY deploy/docker/conf/frontier.yaml.template /opt/liaison/conf/frontier.yaml.template
# Northflank template: same as deploy/docker/conf/liaison.yaml.template
# except manager TLS is disabled (Northflank ingress terminates TLS).
COPY deploy/northflank/liaison.yaml.template /opt/liaison/conf/liaison.yaml.template
COPY deploy/northflank/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/entrypoint-liaison.sh /usr/local/bin/entrypoint-frontier.sh \
        /usr/local/bin/start.sh /opt/liaison/bin/liaison \
        /opt/liaison/bin/password-generator /opt/liaison/bin/frontier

USER liaison
WORKDIR /opt/liaison
EXPOSE 8080 30012
ENTRYPOINT ["/usr/local/bin/start.sh"]
