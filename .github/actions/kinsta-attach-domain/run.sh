#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../_lib/kinsta-api.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/kinsta-api.sh"

SITE_ID="${INPUT_SITE_ID:-}"
ENVIRONMENT_ID="${INPUT_ENVIRONMENT_ID:-}"
REPOSITORY="${INPUT_REPOSITORY:-}"
BASE_DOMAIN="${INPUT_BASE_DOMAIN:-}"
KINSTA_API_URL="${INPUT_KINSTA_API_URL:-}"
KINSTA_TOKEN="${INPUT_KINSTA_API_KEY:-}"

if [[ -z "$SITE_ID" || -z "$ENVIRONMENT_ID" || -z "$REPOSITORY" || -z "$BASE_DOMAIN" || -z "$KINSTA_API_URL" || -z "$KINSTA_TOKEN" ]]; then
  echo "Missing required input(s) for domain attachment" >&2
  exit 2
fi

PROJECT_NAME="${REPOSITORY##*/}"
PROJECT_NAME="${PROJECT_NAME%-bedrock}"
PROJECT_NAME="${PROJECT_NAME%-trellis}"
PROJECT_NAME="${PROJECT_NAME%-radicle}"
PROJECT_NAME="${PROJECT_NAME#www.}"
PROJECT_NAME="${PROJECT_NAME%%.*}"
PROJECT_NAME="$(tr '[:upper:]' '[:lower:]' <<<"$PROJECT_NAME")"

if ! [[ "$PROJECT_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "Could not derive a valid hostname label from repository '$REPOSITORY'" >&2
  exit 3
fi

PRIMARY_DOMAIN="$PROJECT_NAME.$BASE_DOMAIN"
echo "Derived primary domain: $PRIMARY_DOMAIN"

KINSTA_AUTH_HEADER="Authorization: Bearer ${KINSTA_TOKEN}"
SCRATCH_DIR="${RUNNER_TEMP:?RUNNER_TEMP is not set}"
DOMAINS_FILE="$SCRATCH_DIR/kinsta-domains.json"
CREATE_FILE="$SCRATCH_DIR/kinsta-domain-create.json"
OP_FILE="$SCRATCH_DIR/kinsta-domain-op.json"

lookup_domain_id() {
  local STATUS_CODE

  STATUS_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$DOMAINS_FILE" \
    --header "$KINSTA_AUTH_HEADER" \
    "$KINSTA_API_URL/sites/environments/$ENVIRONMENT_ID/domains")" || true

  if [[ "$STATUS_CODE" != "200" ]]; then
    cat "$DOMAINS_FILE" >&2 || true
    echo "Unable to list domains for environment $ENVIRONMENT_ID (HTTP $STATUS_CODE)" >&2
    exit 4
  fi

  jq -r --arg name "$PRIMARY_DOMAIN" \
    '[.environment.site_domains[]? | select(.name == $name) | .id] | .[0] // empty' "$DOMAINS_FILE"
}

DOMAIN_ID="$(lookup_domain_id)"

if [[ -n "$DOMAIN_ID" ]]; then
  echo "Domain '$PRIMARY_DOMAIN' is already attached."
else
  ENVS_FILE="$SCRATCH_DIR/kinsta-envs.json"

  if ! fetch_environments "$KINSTA_API_URL" "$KINSTA_TOKEN" "$SITE_ID" "$ENVS_FILE"; then
    exit 9
  fi

  OTHER_ENV="$(jq -r --arg name "$PRIMARY_DOMAIN" --arg env "$ENVIRONMENT_ID" '
    [ .site.environments[]?
      | select(.id != $env)
      | select(any(.domains[]?; .name == $name))
      | .name
    ] | .[0] // empty
  ' "$ENVS_FILE")"

  if [[ -n "$OTHER_ENV" ]]; then
    echo "Domain '$PRIMARY_DOMAIN' is already attached to the '$OTHER_ENV' environment of this site." >&2
    echo "Detach it there first, or the environments will contend for the same hostname." >&2
    exit 10
  fi

  if ! wait_for_environment_unblocked "$KINSTA_API_URL" "$KINSTA_TOKEN" "$SITE_ID" \
    "$ENVIRONMENT_ID" 60 15 "$SCRATCH_DIR/kinsta-envs-blocked.json"; then
    exit 8
  fi

  PAYLOAD="$(jq -n --arg domain_name "$PRIMARY_DOMAIN" \
    '{domain_name: $domain_name, setup_type: "quick"}')"

  STATUS_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$CREATE_FILE" \
    --request POST \
    --header "$KINSTA_AUTH_HEADER" \
    --header "Content-Type: application/json" \
    --data "$PAYLOAD" \
    "$KINSTA_API_URL/sites/environments/$ENVIRONMENT_ID/domains")" || true

  if [[ "$STATUS_CODE" != "202" && "$STATUS_CODE" != "200" && "$STATUS_CODE" != "201" ]]; then
    cat "$CREATE_FILE" >&2 || true
    echo "Unable to add domain '$PRIMARY_DOMAIN' (HTTP $STATUS_CODE)" >&2
    exit 5
  fi

  OPERATION_ID="$(jq -r '.operation_id // empty' "$CREATE_FILE")"

  if [[ -n "$OPERATION_ID" ]] && ! poll_kinsta_operation \
    "$KINSTA_API_URL" "$KINSTA_TOKEN" "$OPERATION_ID" 40 15 "$OP_FILE"; then
    exit 6
  fi

  for ((ATTEMPT = 1; ATTEMPT <= 10; ATTEMPT++)); do
    DOMAIN_ID="$(lookup_domain_id)"

    if [[ -n "$DOMAIN_ID" ]]; then
      break
    fi

    echo "Domain '$PRIMARY_DOMAIN' not listed yet (attempt $ATTEMPT/10)."
    sleep 15
  done
fi

if [[ -z "$DOMAIN_ID" ]]; then
  echo "Unable to resolve domain id for '$PRIMARY_DOMAIN'" >&2
  jq -c '[.environment.site_domains[]? | {id, name}]' "$DOMAINS_FILE" >&2 || true
  exit 7
fi

POINTING_TARGET="$PROJECT_NAME.hosting.kinsta.cloud"

RECORDS_JSON="$(jq -n -c \
  --arg name "$PRIMARY_DOMAIN" \
  --arg value "$POINTING_TARGET" \
  '[{name: $name, type: "CNAME", value: $value, proxied: true}]')"

echo "Pointing record: $PRIMARY_DOMAIN CNAME $POINTING_TARGET"

if ! wait_for_environment_unblocked "$KINSTA_API_URL" "$KINSTA_TOKEN" "$SITE_ID" \
  "$ENVIRONMENT_ID" 60 15 "$SCRATCH_DIR/kinsta-envs-blocked.json"; then
  exit 11
fi

{
  echo "PRIMARY_DOMAIN=$PRIMARY_DOMAIN"
  echo "DOMAIN_ID=$DOMAIN_ID"
  echo "RECORDS_JSON=$RECORDS_JSON"
} >> "$GITHUB_OUTPUT"
