#!/usr/bin/env bash
# Poll the AAP controller API through the platform gateway until it answers
# HTTP 200 with the admin credentials. Terraform runs this (local-exec) so that
# `terraform apply` only finishes once AAP is usable. It can also be run by hand:
#
#   AAP_URL=https://aap.example.com AAP_USERNAME=admin AAP_PASSWORD=... ./wait_for_aap.sh
set -uo pipefail

: "${AAP_URL:?AAP_URL is required}" "${AAP_USERNAME:?AAP_USERNAME is required}" "${AAP_PASSWORD:?AAP_PASSWORD is required}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-60}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"

url="${AAP_URL%/}/api/controller/v2/ping/"
deadline=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
# curl reads the credentials from stdin (-K -) so they never show up in `ps`.
escaped_password=${AAP_PASSWORD//\\/\\\\}
escaped_password=${escaped_password//\"/\\\"}
auth_config=$(printf 'user = "%s:%s"' "${AAP_USERNAME}" "${escaped_password}")

echo "Waiting up to ${TIMEOUT_MINUTES} minutes for ${url} (a fresh AAP install takes roughly 20-40 minutes) ..."
while :; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 -K - "${url}" <<<"${auth_config}" || true)
  if [ "${code}" = "200" ]; then
    echo "AAP is ready: ${AAP_URL}"
    exit 0
  fi
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "Timed out after ${TIMEOUT_MINUTES} minutes (last HTTP status: ${code:-none})." >&2
    echo "Inspect the node: sudo tail -f /var/log/aap-install.log" >&2
    exit 1
  fi
  echo "$(date -u +%H:%M:%S) not ready yet (HTTP ${code:-000}); next check in ${INTERVAL_SECONDS}s"
  sleep "${INTERVAL_SECONDS}"
done
