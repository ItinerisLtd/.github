#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="${INPUT_SSH_HOST:-}"
SSH_PORT="${INPUT_SSH_PORT:-}"
TRELLIS_ENVIRONMENT="${INPUT_TRELLIS_ENVIRONMENT:-}"
HOSTS_FILE="${INPUT_HOSTS_FILE:-}"

if [[ -z "$TRELLIS_ENVIRONMENT" || -z "$HOSTS_FILE" ]]; then
  echo "Missing required input(s)" >&2
  exit 2
fi

TRELLIS_ENV_NORMALISED="$(tr '[:upper:]' '[:lower:]' <<<"$TRELLIS_ENVIRONMENT")"
read -r TRELLIS_ENV_NORMALISED <<<"$TRELLIS_ENV_NORMALISED"
case "$TRELLIS_ENV_NORMALISED" in
  live | production)
    echo "Refusing to rewrite SSH details for '$TRELLIS_ENVIRONMENT'." >&2
    echo "This rewrite is for non-production environments only." >&2
    exit 1
    ;;
esac

if [[ -z "$SSH_HOST" || -z "$SSH_PORT" ]]; then
  echo "SSH_HOST and SSH_PORT must be given together." >&2
  exit 1
fi

IPV4_OCTET='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
if ! [[ "$SSH_HOST" =~ ^${IPV4_OCTET}(\.${IPV4_OCTET}){3}$ ]]; then
  echo "SSH_HOST '$SSH_HOST' is not an IPv4 address." >&2
  exit 1
fi

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
  echo "SSH_PORT '$SSH_PORT' is not a number." >&2
  exit 1
fi

if ((10#$SSH_PORT < 1 || 10#$SSH_PORT > 65535)); then
  echo "SSH_PORT '$SSH_PORT' is not a valid TCP port (1-65535)." >&2
  exit 1
fi

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "$HOSTS_FILE does not exist. Trellis has no inventory for this environment." >&2
  exit 1
fi

HOST_LINES="$(grep -cE '^[^#[:space:]]+[[:space:]].*ansible_host=' "$HOSTS_FILE" || true)"
if [[ "$HOST_LINES" != "1" ]]; then
  echo "Expected exactly one host line in $HOSTS_FILE, found $HOST_LINES." >&2
  cat "$HOSTS_FILE" >&2
  exit 1
fi

sed -i -E '/^[^#[:space:]]+[[:space:]].*ansible_host=/ {
  s/ansible_host=[^[:space:]]+/ansible_host='"$SSH_HOST"'/
  s/ansible_port=[^[:space:]]+/ansible_port='"$SSH_PORT"'/
}' "$HOSTS_FILE"

if ! grep -E '^[^#[:space:]]+[[:space:]]' "$HOSTS_FILE" | grep -F -q "ansible_host=$SSH_HOST"; then
  echo "Failed to set ansible_host in $HOSTS_FILE." >&2
  cat "$HOSTS_FILE" >&2
  exit 1
fi

if ! grep -E '^[^#[:space:]]+[[:space:]]' "$HOSTS_FILE" | grep -F -q "ansible_port=$SSH_PORT"; then
  sed -i -E "/^[^#[:space:]]+[[:space:]].*ansible_host=$SSH_HOST/ s/\$/ ansible_port=$SSH_PORT/" "$HOSTS_FILE"
fi

if ! grep -E '^[^#[:space:]]+[[:space:]]' "$HOSTS_FILE" | grep -F -q "ansible_port=$SSH_PORT"; then
  echo "Failed to set ansible_port in $HOSTS_FILE." >&2
  cat "$HOSTS_FILE" >&2
  exit 1
fi

grep -E '^[^#[:space:]]+[[:space:]]' "$HOSTS_FILE"
