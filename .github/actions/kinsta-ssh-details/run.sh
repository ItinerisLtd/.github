#!/usr/bin/env bash
set -euo pipefail

SITE_ID="${INPUT_SITE_ID:-}"
ENVIRONMENT_ID="${INPUT_ENVIRONMENT_ID:-}"
ENVIRONMENT="${INPUT_ENVIRONMENT:-}"
KINSTA_API_URL="${INPUT_KINSTA_API_URL:-}"
KINSTA_API_KEY="${INPUT_KINSTA_API_KEY:-}"

if [[ -z "$SITE_ID" || -z "$ENVIRONMENT_ID" || -z "$ENVIRONMENT" || -z "$KINSTA_API_URL" || -z "$KINSTA_API_KEY" ]]; then
  echo "Missing required input(s) for SSH details" >&2
  exit 2
fi

CONFIG_FILE="${RUNNER_TEMP:?RUNNER_TEMP is not set}/kinsta-ssh-config.json"

STATUS_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$CONFIG_FILE" \
  --header "Authorization: Bearer ${KINSTA_API_KEY}" \
  "$KINSTA_API_URL/sites/$SITE_ID/environments/$ENVIRONMENT_ID/ssh/config")" || true

if [[ "$STATUS_CODE" != "200" ]]; then
  cat "$CONFIG_FILE" >&2 || true
  echo "Unable to read SSH details (HTTP $STATUS_CODE)" >&2
  exit 3
fi

SSH_USER="$(jq -r '.user // empty' "$CONFIG_FILE")"
SSH_HOST="$(jq -r '.host // empty' "$CONFIG_FILE")"
SSH_PORT="$(jq -r '.port // empty' "$CONFIG_FILE")"

if [[ -z "$SSH_USER" || -z "$SSH_HOST" || -z "$SSH_PORT" ]]; then
  jq -c '.' "$CONFIG_FILE" >&2 || true
  echo "SSH details incomplete" >&2
  exit 4
fi

{
  echo "SSH_USER=$SSH_USER"
  echo "SSH_HOST=$SSH_HOST"
  echo "SSH_PORT=$SSH_PORT"
} >> "$GITHUB_OUTPUT"

{
  echo "## Kinsta SSH details for \`$ENVIRONMENT\`"
  echo
  echo "Trellis needs these before it can deploy to this environment."
  echo
  echo '```'
  echo "trellis/hosts/$ENVIRONMENT"
  echo "  kinsta_$ENVIRONMENT ansible_host=$SSH_HOST ansible_port=$SSH_PORT ansible_python_interpreter=/usr/bin/python3"
  echo
  echo "bedrock/wp-cli.trellis-alias.yml"
  echo "  @$ENVIRONMENT:"
  echo "    ssh: \"$SSH_USER@$SSH_HOST:$SSH_PORT\""
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

echo "SSH: $SSH_USER@$SSH_HOST:$SSH_PORT"
