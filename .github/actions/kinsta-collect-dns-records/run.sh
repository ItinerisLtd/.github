#!/usr/bin/env bash
set -euo pipefail

DOMAIN_ID="${INPUT_DOMAIN_ID:-}"
KINSTA_API_URL="${INPUT_KINSTA_API_URL:-}"
KINSTA_API_KEY="${INPUT_KINSTA_API_KEY:-}"
MAX_ATTEMPTS="${INPUT_MAX_ATTEMPTS:-4}"
SLEEP_SECONDS="${INPUT_SLEEP_SECONDS:-15}"

if [[ -z "$DOMAIN_ID" || -z "$KINSTA_API_URL" || -z "$KINSTA_API_KEY" ]]; then
  echo "Missing required input(s) for DNS record collection" >&2
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
RECORDS_FILE="${RUNNER_TEMP:?RUNNER_TEMP is not set}/kinsta-dns-records.json"

records_json() {
  jq -c '
    ((.site_domain.verification_records // []) | map(. + {proxied: false}))
    + ((.site_domain.pointing_records // []) | map(. + {proxied: true}))
  ' "$RECORDS_FILE"
}

fall_back_to_constructed_record() {
  echo "$1"
  echo "Using the constructed pointing record alone."
  echo "RECORDS_JSON=[]" >> "$GITHUB_OUTPUT"
  exit 0
}

LAST_STATUS=''

fetch_records() {
  local STATUS_CODE

  STATUS_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$RECORDS_FILE" \
    --header "$KINSTA_AUTH_HEADER" \
    "$KINSTA_API_URL/sites/environments/domains/$DOMAIN_ID/verification-records")" || true

  LAST_STATUS="$STATUS_CODE"

  if [[ "$STATUS_CODE" == "401" || "$STATUS_CODE" == "403" ]]; then
    cat "$RECORDS_FILE" >&2 || true
    echo "Kinsta DNS record lookup failed with HTTP $STATUS_CODE" >&2
    exit 3
  fi

  # A domain attached with setup_type "quick" has nothing to verify, so Kinsta
  # answers 404. That is an expected state, not a provisioning failure.
  if [[ "$STATUS_CODE" == "404" ]]; then
    fall_back_to_constructed_record "Kinsta holds no verification records for this domain (HTTP 404)."
  fi

  [[ "$STATUS_CODE" == "200" ]]
}

SAW_SUCCESS=false

for ((ATTEMPT = 1; ATTEMPT <= MAX_ATTEMPTS; ATTEMPT++)); do
  if fetch_records; then
    SAW_SUCCESS=true
    RECORD_COUNT="$(jq -r '
      ((.site_domain.verification_records // [])
        + (.site_domain.pointing_records // [])) | length
    ' "$RECORDS_FILE")"

    if [[ "$RECORD_COUNT" -gt 0 ]]; then
      echo "Kinsta reports: $(jq -c '.' "$RECORDS_FILE")"
      echo "RECORDS_JSON=$(records_json)" >> "$GITHUB_OUTPUT"
      echo "Collected $RECORD_COUNT record(s) from Kinsta."
      exit 0
    fi
  fi

  if [[ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; then
    echo "No records from Kinsta yet (attempt $ATTEMPT/$MAX_ATTEMPTS)."
    sleep "$SLEEP_SECONDS"
  fi
done

if [[ "$SAW_SUCCESS" != "true" ]]; then
  echo "Kinsta DNS record lookup never succeeded in $MAX_ATTEMPTS attempts." >&2
  echo "Last response was HTTP ${LAST_STATUS:-000}:" >&2
  cat "$RECORDS_FILE" >&2 || true
  exit 3
fi

fall_back_to_constructed_record "Kinsta reported no DNS records after $MAX_ATTEMPTS attempts."
