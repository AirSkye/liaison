#!/bin/bash
# Northflank single-container start: frontier + liaison in one container.
# - frontier runs in the background (its entrypoint waits for the shared
#   self-signed cert, which the liaison entrypoint generates on first run).
# - liaison runs in the foreground via the stock entrypoint, which renders
#   liaison.yaml, seeds the first admin user and prints the one-time
#   password to the logs. Read it with the Northflank log view.
# - guacd is not present in v1: WebDesktop (RDP/VNC) is unavailable.
#   Everything else (SSH, DB, files, LLM, Edge) does not need it.
set -eu

: "${MANAGER_PORT:=8080}"
: "${FRONTIER_PORT:=30012}"
: "${FRONTIER_CONTROLPLANE_PORT:=30010}"
: "${LIAISON_PUBLIC_HOST:=localhost}"
: "${LIAISON_ADMIN_EMAIL:=default@liaison.com}"
: "${GUACD_ADDR:=127.0.0.1:4822}"
: "${GUACD_BRIDGE_ADDR:=127.0.0.1:0}"
: "${GUACD_BRIDGE_HOST:=127.0.0.1}"
: "${AGENT_ENABLED:=false}"
: "${AGENT_OUTPUT_LANGUAGE:=zh}"
export MANAGER_PORT FRONTIER_PORT FRONTIER_CONTROLPLANE_PORT \
    LIAISON_PUBLIC_HOST LIAISON_ADMIN_EMAIL \
    GUACD_ADDR GUACD_BRIDGE_ADDR GUACD_BRIDGE_HOST \
    AGENT_ENABLED AGENT_OUTPUT_LANGUAGE

# server_url: Northflank ingress terminates TLS, so the console URL is
# https://<northflank-host> with no port, even though the container itself
# serves plain HTTP on $MANAGER_PORT.
if [ -z "${SERVER_URL:-}" ]; then
    SERVER_URL="https://${LIAISON_PUBLIC_HOST}"
fi
export SERVER_URL

echo "[start] manager on 0.0.0.0:${MANAGER_PORT} (plain HTTP behind Northflank TLS), frontier on 0.0.0.0:${FRONTIER_PORT}, server_url=${SERVER_URL}"

/usr/local/bin/entrypoint-frontier.sh /opt/liaison/bin/frontier --config /opt/liaison/conf/frontier.yaml &
FRONTIER_PID=$!
echo "[start] frontier pid ${FRONTIER_PID}"

# exec replaces this shell; the backgrounded frontier keeps running.
exec /usr/local/bin/entrypoint-liaison.sh /opt/liaison/bin/liaison -c /opt/liaison/conf/liaison.yaml
