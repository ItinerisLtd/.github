#!/usr/bin/env bash
set -euo pipefail

CLOUDFLARE_TOKEN="${INPUT_CLOUDFLARE_API_TOKEN:-}"
ZONE_ID="${INPUT_ZONE_ID:-}"
RECORDS_JSON="${INPUT_RECORDS_JSON:-}"

if [[ -z "$CLOUDFLARE_TOKEN" ]]; then
  echo "Missing INPUT_CLOUDFLARE_API_TOKEN" >&2
  exit 2
fi

if [[ -z "$ZONE_ID" ]]; then
  echo "Missing INPUT_ZONE_ID. Pass the CLOUDFLARE_ZONE_ID_DEV secret." >&2
  exit 2
fi

if [[ -z "$RECORDS_JSON" ]]; then
  echo "Missing INPUT_RECORDS_JSON" >&2
  exit 2
fi

if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$RECORDS_JSON"; then
  echo "INPUT_RECORDS_JSON must be a JSON array" >&2
  exit 2
fi

ADDITIONAL_RECORDS_JSON="${INPUT_ADDITIONAL_RECORDS_JSON:-[]}"

if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$ADDITIONAL_RECORDS_JSON"; then
  echo "INPUT_ADDITIONAL_RECORDS_JSON must be a JSON array" >&2
  exit 2
fi

RECORDS_JSON="$(jq -c -n --argjson a "$RECORDS_JSON" --argjson b "$ADDITIONAL_RECORDS_JSON" '
  ($a + ($b | map(select(. as $r | ($a | any(.name == $r.name)) | not))))
  | unique_by([.name, .type, (.value // .content), (.proxied // false)])
')"

# A CNAME cannot share a name with any other record, so a Kinsta record at the
# same name as the constructed pointing record is unusable rather than merely
# redundant.
DROPPED="$(jq -n --argjson a "$RECORDS_JSON" --argjson b "$ADDITIONAL_RECORDS_JSON" \
  '[$b[] | select(. as $r | ($a | any(.name == $r.name and .type == $r.type)) | not) | "\(.type) \(.name)"] | join(", ")')"

if [[ -n "$DROPPED" && "$DROPPED" != "null" ]]; then
  echo "::warning::Skipped, because the pointing CNAME already occupies that name: $DROPPED"
fi

AUTH_HEADER="Authorization: Bearer ${CLOUDFLARE_TOKEN}"
ZONE_API="https://api.cloudflare.com/client/v4/zones/$ZONE_ID"
RESPONSE_FILE="${RUNNER_TEMP:?RUNNER_TEMP is not set}/cloudflare-response.json"

# curl --fail throws the response body away, and Cloudflare puts the only
# usable diagnosis (for example 81053, "record with that host already exists")
# in that body.
cf_api() {
  local LABEL="$1" METHOD="$2" URL="$3" DATA="${4:-}"
  local STATUS_CODE
  local ARGS=(--silent --show-error --write-out '%{http_code}' --output "$RESPONSE_FILE"
    --request "$METHOD" --header "$AUTH_HEADER" --max-time 30)

  if [[ -n "$DATA" ]]; then
    ARGS+=(--header "Content-Type: application/json" --data "$DATA")
  fi

  STATUS_CODE="$(curl "${ARGS[@]}" "$URL")" || true

  if [[ "$STATUS_CODE" != "200" && "$STATUS_CODE" != "201" ]]; then
    echo "Cloudflare $LABEL failed with HTTP ${STATUS_CODE:-000}" >&2

    local ERRORS
    if ERRORS="$(jq -r '(.errors // []) | map("  \(.code): \(.message)") | join("\n")' \
      "$RESPONSE_FILE" 2>/dev/null)" && [[ -n "$ERRORS" ]]; then
      echo "$ERRORS" >&2
    else
      cat "$RESPONSE_FILE" >&2 || true
    fi

    return 1
  fi

  cat "$RESPONSE_FILE"
}

ZONE_RESP="$(cf_api "zone lookup" GET "$ZONE_API")"
ZONE_NAME="$(jq -r '.result.name // empty' <<<"$ZONE_RESP")"

if [[ -z "$ZONE_NAME" ]]; then
  echo "Unable to resolve the zone name for the given zone id" >&2
  exit 3
fi

fqdn() {
  local NAME="${1%.}"

  if [[ "$NAME" == "@" || -z "$NAME" ]]; then
    printf '%s' "$ZONE_NAME"
    return 0
  fi

  if [[ "$NAME" == "$ZONE_NAME" || "$NAME" == *".$ZONE_NAME" ]]; then
    printf '%s' "$NAME"
    return 0
  fi

  printf '%s.%s' "$NAME" "$ZONE_NAME"
}

record_payload() {
  jq -n \
    --arg type "$1" \
    --arg name "$2" \
    --arg content "$3" \
    --argjson proxied "$4" \
    '{type: $type, name: $name, content: $content, ttl: 1, proxied: $proxied}'
}

APPLIED=0
while IFS= read -r ROW; do
  RECORD_NAME="$(jq -r '.name // empty' <<<"$ROW")"
  RECORD_TYPE="$(jq -r '.type // empty' <<<"$ROW")"
  RECORD_CONTENT="$(jq -r '.value // .content // empty' <<<"$ROW")"
  PROXIED="$(jq -r 'if .proxied == true then "true" else "false" end' <<<"$ROW")"

  if [[ -z "$RECORD_NAME" || -z "$RECORD_TYPE" || -z "$RECORD_CONTENT" ]]; then
    echo "Skipping malformed record: $ROW" >&2
    continue
  fi

  RECORD_NAME="$(fqdn "$RECORD_NAME")"
  RECORD_TYPE="$(tr '[:lower:]' '[:upper:]' <<<"$RECORD_TYPE")"
  QUERY_NAME="$(jq -rn --arg v "$RECORD_NAME" '$v | @uri')"

  # Queried without a type filter, so a record of a conflicting type at the same
  # name is seen rather than silently missed until the write fails.
  QUERY_RESP="$(cf_api "lookup of $RECORD_NAME" GET "$ZONE_API/dns_records?name=$QUERY_NAME&per_page=100")"

  SAME_TYPE="$(jq -c --arg type "$RECORD_TYPE" '[.result[] | select(.type == $type)]' <<<"$QUERY_RESP")"
  CONFLICTING="$(jq -r --arg type "$RECORD_TYPE" \
    '[.result[] | select(.type != $type) | select($type == "CNAME" or .type == "CNAME") | "\(.type) -> \(.content)"] | join(", ")' \
    <<<"$QUERY_RESP")"

  EXACT_COUNT="$(jq -r --arg content "$RECORD_CONTENT" --argjson proxied "$PROXIED" \
    '[.[] | select(.content == $content and (.proxied // false) == $proxied)] | length' <<<"$SAME_TYPE")"
  CANDIDATE_COUNT="$(jq -r 'length' <<<"$SAME_TYPE")"

  if [[ "$EXACT_COUNT" -gt 0 ]]; then
    echo "$RECORD_TYPE $RECORD_NAME already points at $RECORD_CONTENT (proxied=$PROXIED)."
    continue
  fi

  if [[ -n "$CONFLICTING" ]]; then
    echo "::warning::$RECORD_NAME already holds $CONFLICTING, which cannot coexist with a $RECORD_TYPE record. Remove it in Cloudflare, or the write below fails."
  fi

  PAYLOAD="$(record_payload "$RECORD_TYPE" "$RECORD_NAME" "$RECORD_CONTENT" "$PROXIED")"
  RECORD_ID=''

  # TXT, MX, SRV and CAA legitimately hold several values at one name, so an
  # existing record is added to rather than overwritten.
  if [[ "$RECORD_TYPE" != "TXT" && "$RECORD_TYPE" != "MX" && "$RECORD_TYPE" != "SRV" && "$RECORD_TYPE" != "CAA" ]]; then
    RECORD_ID="$(jq -r '.[0].id // empty' <<<"$SAME_TYPE")"
  fi

  if [[ -n "$RECORD_ID" ]]; then
    OLD_CONTENT="$(jq -r '.[0].content // empty' <<<"$SAME_TYPE")"
    echo "Updating $RECORD_TYPE $RECORD_NAME: '$OLD_CONTENT' -> '$RECORD_CONTENT' (proxied=$PROXIED)"
    cf_api "update of $RECORD_TYPE $RECORD_NAME" PUT "$ZONE_API/dns_records/$RECORD_ID" "$PAYLOAD" >/dev/null
  else
    echo "Creating $RECORD_TYPE $RECORD_NAME -> $RECORD_CONTENT (proxied=$PROXIED)"

    if [[ "$CANDIDATE_COUNT" -gt 0 ]]; then
      echo "::warning::$RECORD_TYPE $RECORD_NAME already has $CANDIDATE_COUNT record(s) with other values; review for stale entries."
    fi

    cf_api "creation of $RECORD_TYPE $RECORD_NAME" POST "$ZONE_API/dns_records" "$PAYLOAD" >/dev/null
  fi

  APPLIED=$((APPLIED + 1))
done < <(jq -c '.[]' <<<"$RECORDS_JSON")

echo "RECORDS_APPLIED=$APPLIED" >> "$GITHUB_OUTPUT"
