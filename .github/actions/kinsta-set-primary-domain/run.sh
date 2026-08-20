#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../_lib/kinsta-api.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/kinsta-api.sh"

SITE_ID="${INPUT_SITE_ID:-}"
ENVIRONMENT_ID="${INPUT_ENVIRONMENT_ID:-}"
DOMAIN_ID="${INPUT_DOMAIN_ID:-}"
KINSTA_API_URL="${INPUT_KINSTA_API_URL:-}"
KINSTA_API_KEY="${INPUT_KINSTA_API_KEY:-}"
RUN_SEARCH_AND_REPLACE="${INPUT_RUN_SEARCH_AND_REPLACE:-true}"
MAX_ATTEMPTS="${INPUT_MAX_ATTEMPTS:-40}"
SLEEP_SECONDS="${INPUT_SLEEP_SECONDS:-15}"

if [[ -z "$SITE_ID" || -z "$ENVIRONMENT_ID" || -z "$DOMAIN_ID" || -z "$KINSTA_API_URL" || -z "$KINSTA_API_KEY" ]]; then
  echo "Missing required input(s) for primary domain assignment" >&2
  exit 2
fi

if [[ "$RUN_SEARCH_AND_REPLACE" != "true" && "$RUN_SEARCH_AND_REPLACE" != "false" ]]; then
  echo "RUN_SEARCH_AND_REPLACE must be 'true' or 'false'" >&2
  exit 2
fi

if ! [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || ! [[ "$SLEEP_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "MAX_ATTEMPTS and SLEEP_SECONDS must be integers" >&2
  exit 2
fi

if [[ "$MAX_ATTEMPTS" -lt 1 || "$SLEEP_SECONDS" -lt 1 ]]; then
  echo "MAX_ATTEMPTS and SLEEP_SECONDS must be greater than zero" >&2
  exit 2
fi

KINSTA_AUTH_HEADER="Authorization: Bearer ${KINSTA_API_KEY}"
SCRATCH_DIR="${RUNNER_TEMP:?RUNNER_TEMP is not set}"
CHANGE_FILE="$SCRATCH_DIR/kinsta-primary-domain.json"
OP_FILE="$SCRATCH_DIR/kinsta-primary-domain-op.json"

ENVS_FILE="$SCRATCH_DIR/kinsta-envs.json"

if ! fetch_environments "$KINSTA_API_URL" "$KINSTA_API_KEY" "$SITE_ID" "$ENVS_FILE"; then
  exit 8
fi

CURRENT_PRIMARY_ID="$(jq -r --arg env "$ENVIRONMENT_ID" \
  '[.site.environments[]? | select(.id == $env) | .primaryDomain.id // empty] | .[0] // empty' "$ENVS_FILE")"

if [[ "$CURRENT_PRIMARY_ID" == "$DOMAIN_ID" ]]; then
  echo "Domain $DOMAIN_ID is already the primary domain; nothing to do."
  exit 0
fi

if ! wait_for_environment_unblocked "$KINSTA_API_URL" "$KINSTA_API_KEY" "$SITE_ID" \
  "$ENVIRONMENT_ID" 60 15 "$SCRATCH_DIR/kinsta-envs-blocked.json"; then
  exit 7
fi

PAYLOAD="$(jq -n \
  --arg domain_id "$DOMAIN_ID" \
  --argjson run_search_and_replace "$RUN_SEARCH_AND_REPLACE" \
  '{domain_id: $domain_id, run_search_and_replace: $run_search_and_replace}')"

STATUS_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$CHANGE_FILE" \
  --request PUT \
  --header "$KINSTA_AUTH_HEADER" \
  --header "Content-Type: application/json" \
  --data "$PAYLOAD" \
  "$KINSTA_API_URL/sites/environments/$ENVIRONMENT_ID/change-primary-domain")" || true

if [[ "$STATUS_CODE" != "202" && "$STATUS_CODE" != "200" ]]; then
  cat "$CHANGE_FILE" >&2 || true
  echo "Failed to set primary domain $DOMAIN_ID (HTTP $STATUS_CODE)" >&2
  exit 3
fi

OPERATION_ID="$(jq -r '.operation_id // empty' "$CHANGE_FILE")"
if [[ -z "$OPERATION_ID" ]]; then
  echo "Primary domain set without an operation to poll."
  exit 0
fi

if ! poll_kinsta_operation "$KINSTA_API_URL" "$KINSTA_API_KEY" "$OPERATION_ID" \
  "$MAX_ATTEMPTS" "$SLEEP_SECONDS" "$OP_FILE"; then
  exit 4
fi

if ! wait_for_primary_domain "$KINSTA_API_URL" "$KINSTA_API_KEY" "$SITE_ID" \
  "$ENVIRONMENT_ID" "$DOMAIN_ID" "$MAX_ATTEMPTS" "$SLEEP_SECONDS" "$ENVS_FILE"; then
  exit 5
fi

if ! wait_for_environment_unblocked "$KINSTA_API_URL" "$KINSTA_API_KEY" "$SITE_ID" \
  "$ENVIRONMENT_ID" 60 15 "$SCRATCH_DIR/kinsta-envs-blocked.json"; then
  exit 6
fi

echo "Primary domain set and search-replace finished."
