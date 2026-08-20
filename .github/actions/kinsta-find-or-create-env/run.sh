#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../_lib/kinsta-api.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/kinsta-api.sh"

TARGET_ENV="${INPUT_TARGET_ENVIRONMENT:-}"
SITE_ID="${INPUT_SITE_ID:-}"
API_URL="${INPUT_KINSTA_API_URL:-}"
API_KEY="${INPUT_KINSTA_API_KEY:-}"

if [[ -z "$TARGET_ENV" || -z "$SITE_ID" || -z "$API_URL" || -z "$API_KEY" ]]; then
  echo "Missing required input(s)" >&2
  exit 2
fi

SCRATCH_DIR="${RUNNER_TEMP:?RUNNER_TEMP is not set}"
OP_JSON_FILE="$SCRATCH_DIR/kinsta-op.json"

if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$TARGET_ENV")" == \
      "$(tr '[:upper:]' '[:lower:]' <<<"${INPUT_SOURCE_ENVIRONMENT:-live}")" ]]; then
  echo "Target and source environment are both '$TARGET_ENV'." >&2
  echo "Refusing to reconfigure the source environment in place." >&2
  exit 13
fi

KINSTA_AUTH_HEADER=("Authorization: Bearer ${API_KEY}")
KINSTA_CT_HEADER=("Content-Type: application/json")

get_envs() {
  curl --silent --show-error --fail \
    --header "${KINSTA_AUTH_HEADER[0]}" \
    --header "${KINSTA_CT_HEADER[0]}" \
    "$API_URL/sites/$SITE_ID/environments"
}

ENVS_JSON="$(get_envs)"

TARGET_ID="$(jq -r --arg n "$TARGET_ENV" '.site.environments[] | select((.name | ascii_downcase) == ($n | ascii_downcase) or (.display_name | ascii_downcase) == ($n | ascii_downcase)) | .id' <<<"$ENVS_JSON" | head -n1)"

CREATED='false'

if [[ -z "${TARGET_ID:-}" || "$TARGET_ID" == "null" ]]; then
  SOURCE_ENV="${INPUT_SOURCE_ENVIRONMENT:-live}"
  SOURCE_ID="$(jq -r --arg n "$SOURCE_ENV" '.site.environments[] | select((.name | ascii_downcase) == ($n | ascii_downcase) or (.display_name | ascii_downcase) == ($n | ascii_downcase)) | .id' <<<"$ENVS_JSON" | head -n1)"

  if [[ -z "${SOURCE_ID:-}" || "$SOURCE_ID" == "null" ]]; then
    echo "Source environment '$SOURCE_ENV' not found on site $SITE_ID" >&2
    exit 3
  fi

  DISPLAY_NAME="$(tr '[:lower:]' '[:upper:]' <<<"${TARGET_ENV:0:1}")${TARGET_ENV:1}"

  CLONE_PAYLOAD="$(jq -n --arg dn "$DISPLAY_NAME" --arg sid "$SOURCE_ID" \
    '{display_name: $dn, is_premium: false, source_env_id: $sid}')"

  CLONE_RESP="$(curl --silent --show-error --fail \
    --request POST \
    --header "${KINSTA_AUTH_HEADER[0]}" \
    --header "${KINSTA_CT_HEADER[0]}" \
    --data "$CLONE_PAYLOAD" \
    "$API_URL/sites/$SITE_ID/environments/clone")"

  OPERATION_ID="$(jq -r '.operation_id // empty' <<<"$CLONE_RESP")"
  if [[ -z "${OPERATION_ID:-}" ]]; then
    echo "Clone request did not return operation_id" >&2
    echo "Response: $CLONE_RESP" >&2
    exit 4
  fi

  if ! poll_kinsta_operation "$API_URL" "$API_KEY" "$OPERATION_ID" 80 15 "$OP_JSON_FILE"; then
    exit 5
  fi

  for ((LOOKUP = 1; LOOKUP <= 10; LOOKUP++)); do
    ENVS_JSON="$(get_envs)"
    TARGET_ID="$(jq -r --arg n "$TARGET_ENV" '.site.environments[] | select((.name | ascii_downcase) == ($n | ascii_downcase) or (.display_name | ascii_downcase) == ($n | ascii_downcase)) | .id' <<<"$ENVS_JSON" | head -n1)"

    if [[ -n "${TARGET_ID:-}" && "$TARGET_ID" != "null" ]]; then
      break
    fi

    echo "Cloned environment '$TARGET_ENV' not listed yet (attempt $LOOKUP/10)."
    sleep 15
  done

  if [[ -z "${TARGET_ID:-}" || "$TARGET_ID" == "null" ]]; then
    echo "Environment created but id not found after operation" >&2
    jq -c '[.site.environments[] | {id, name, display_name}]' <<<"$ENVS_JSON" >&2 || true
    exit 8
  fi
  CREATED='true'
fi

if ! wait_for_environment_unblocked "$API_URL" "$API_KEY" "$SITE_ID" "$TARGET_ID" 60 15 \
  "$SCRATCH_DIR/kinsta-envs-blocked.json"; then
  exit 12
fi

{
  printf 'CREATED=%s\n' "$CREATED"
  printf 'ENVIRONMENT_ID=%s\n' "$TARGET_ID"
} >> "$GITHUB_OUTPUT"

exit 0
