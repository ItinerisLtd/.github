#!/usr/bin/env bash
set -euo pipefail

DOMAIN_ID="${INPUT_DOMAIN_ID:-}"
PRIMARY_DOMAIN="${INPUT_PRIMARY_DOMAIN:-}"
KINSTA_API_URL="${INPUT_KINSTA_API_URL:-}"
KINSTA_API_KEY="${INPUT_KINSTA_API_KEY:-}"
MAX_ATTEMPTS="${INPUT_MAX_ATTEMPTS:-8}"
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

fetch_records() {
  local STATUS_CODE

  STATUS_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$RECORDS_FILE" \
    --header "$KINSTA_AUTH_HEADER" \
    "$KINSTA_API_URL/sites/environments/domains/$DOMAIN_ID/verification-records")" || true

  if [[ "$STATUS_CODE" == "401" || "$STATUS_CODE" == "403" || "$STATUS_CODE" == "404" ]]; then
    cat "$RECORDS_FILE" >&2 || true
    echo "Kinsta DNS record lookup failed with HTTP $STATUS_CODE" >&2
    exit 3
  fi

  [[ "$STATUS_CODE" == "200" ]]
}

if fetch_records; then
  echo "Kinsta reports: $(jq -c '.' "$RECORDS_FILE")"
fi

if [[ -n "$PRIMARY_DOMAIN" ]] && getent hosts "$PRIMARY_DOMAIN" >/dev/null 2>&1; then
  echo "$PRIMARY_DOMAIN already resolves, so its DNS record is in place."
  {
    echo "RECORDS_JSON=[]"
    echo "DNS_READY=true"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

for ATTEMPT in $(seq 1 "$MAX_ATTEMPTS"); do
  if fetch_records; then
    POINTING_COUNT="$(jq -r '(.site_domain.pointing_records // []) | length' "$RECORDS_FILE")"

    if [[ "$POINTING_COUNT" -gt 0 ]]; then
      {
        echo "RECORDS_JSON=$(records_json)"
        echo "DNS_READY=false"
      } >> "$GITHUB_OUTPUT"
      echo "Collected $POINTING_COUNT pointing record(s) from Kinsta."
      exit 0
    fi
  fi

  if [[ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; then
    echo "No records from Kinsta yet (attempt $ATTEMPT/$MAX_ATTEMPTS)."
    sleep "$SLEEP_SECONDS"
  fi
done

echo "::warning::Kinsta returned no DNS records and ${PRIMARY_DOMAIN:-the hostname} does not resolve."
echo "Falling back to the constructed pointing record."
{
  echo "RECORDS_JSON=[]"
  echo "DNS_READY=false"
} >> "$GITHUB_OUTPUT"
exit 0
