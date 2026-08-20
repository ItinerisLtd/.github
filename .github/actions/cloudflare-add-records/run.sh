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

DROPPED="$(jq -n --argjson a "$RECORDS_JSON" --argjson b "$ADDITIONAL_RECORDS_JSON" \
  '[$b[] | select(. as $r | ($a | any(.name == $r.name and .type == $r.type)) | not) | "\(.type) \(.name)"] | join(", ")')"

if [[ -n "$DROPPED" && "$DROPPED" != "null" ]]; then
  echo "Superseded by the constructed pointing record: $DROPPED"
fi

AUTH_HEADER="Authorization: Bearer ${CLOUDFLARE_TOKEN}"
ZONE_API="https://api.cloudflare.com/client/v4/zones/$ZONE_ID"

ZONE_RESP="$(curl --silent --show-error --fail --header "$AUTH_HEADER" "$ZONE_API")"
ZONE_NAME="$(jq -r '.result.name // empty' <<<"$ZONE_RESP")"

if [[ -z "$ZONE_NAME" ]]; then
  echo "Unable to resolve the zone name for $ZONE_ID" >&2
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
  QUERY_TYPE="$(jq -rn --arg v "$RECORD_TYPE" '$v | @uri')"

  QUERY_RESP="$(curl --silent --show-error --fail \
    --header "$AUTH_HEADER" \
    "$ZONE_API/dns_records?type=$QUERY_TYPE&name=$QUERY_NAME")"

  EXACT_COUNT="$(jq -r --arg content "$RECORD_CONTENT" --argjson proxied "$PROXIED" \
    '[.result[] | select(.content == $content and (.proxied // false) == $proxied)] | length' <<<"$QUERY_RESP")"
  CANDIDATE_COUNT="$(jq -r '.result | length' <<<"$QUERY_RESP")"

  if [[ "$EXACT_COUNT" -gt 0 ]]; then
    echo "$RECORD_TYPE $RECORD_NAME already points at $RECORD_CONTENT (proxied=$PROXIED)."
    continue
  fi

  PAYLOAD="$(record_payload "$RECORD_TYPE" "$RECORD_NAME" "$RECORD_CONTENT" "$PROXIED")"
  RECORD_ID=''

  if [[ "$RECORD_TYPE" != "TXT" && "$RECORD_TYPE" != "MX" && "$RECORD_TYPE" != "SRV" && "$RECORD_TYPE" != "CAA" ]]; then
    RECORD_ID="$(jq -r '.result[0].id // empty' <<<"$QUERY_RESP")"
  fi

  if [[ -n "$RECORD_ID" ]]; then
    OLD_CONTENT="$(jq -r '.result[0].content // empty' <<<"$QUERY_RESP")"
    echo "Updating $RECORD_TYPE $RECORD_NAME: '$OLD_CONTENT' -> '$RECORD_CONTENT' (proxied=$PROXIED)"

    curl --silent --show-error --fail \
      --request PUT \
      --header "$AUTH_HEADER" \
      --header "Content-Type: application/json" \
      --data "$PAYLOAD" \
      "$ZONE_API/dns_records/$RECORD_ID" >/dev/null
  else
    echo "Creating $RECORD_TYPE $RECORD_NAME -> $RECORD_CONTENT (proxied=$PROXIED)"

    if [[ "$CANDIDATE_COUNT" -gt 0 ]]; then
      echo "::warning::$RECORD_TYPE $RECORD_NAME already has $CANDIDATE_COUNT record(s) with other values; review for stale entries."
    fi

    curl --silent --show-error --fail \
      --request POST \
      --header "$AUTH_HEADER" \
      --header "Content-Type: application/json" \
      --data "$PAYLOAD" \
      "$ZONE_API/dns_records" >/dev/null
  fi

  APPLIED=$((APPLIED + 1))
done < <(jq -c '.[]' <<<"$RECORDS_JSON")

echo "RECORDS_APPLIED=$APPLIED" >> "$GITHUB_OUTPUT"
