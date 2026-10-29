#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../_lib/kinsta-api.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/kinsta-api.sh"

SITE_ID="${INPUT_SITE_ID:-}"
ENVIRONMENT_ID="${INPUT_ENVIRONMENT_ID:-}"
PAIRS="${INPUT_PAIRS:-}"
KINSTA_API_URL="${INPUT_KINSTA_API_URL:-}"
KINSTA_API_KEY="${INPUT_KINSTA_API_KEY:-}"
MAX_ATTEMPTS="${INPUT_MAX_ATTEMPTS:-40}"
SLEEP_SECONDS="${INPUT_SLEEP_SECONDS:-15}"

if [[ -z "$SITE_ID" || -z "$ENVIRONMENT_ID" || -z "$KINSTA_API_URL" || -z "$KINSTA_API_KEY" ]]; then
	echo "Missing required input(s) for search-replace" >&2
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
RESPONSE_FILE="$SCRATCH_DIR/kinsta-search-replace.json"
OP_FILE="$SCRATCH_DIR/kinsta-search-replace-op.json"

SEARCHES=()
REPLACES=()

while IFS=$'\t' read -r SEARCH REPLACE EXTRA; do
	SEARCH="${SEARCH%$'\r'}"
	REPLACE="${REPLACE%$'\r'}"

	if [[ -z "$SEARCH" && -z "$REPLACE" ]]; then
		continue
	fi

	if [[ -z "$SEARCH" || -z "$REPLACE" || -n "$EXTRA" ]]; then
		echo "Each PAIRS line must be exactly '<search><TAB><replace>'" >&2
		exit 2
	fi

	SEARCHES+=("$SEARCH")
	REPLACES+=("$REPLACE")
done <<<"$PAIRS"

if [[ "${#SEARCHES[@]}" -eq 0 ]]; then
	echo "No search-replace pairs given; nothing to do."
	exit 0
fi

LAST_INDEX=$((${#SEARCHES[@]} - 1))

for INDEX in "${!SEARCHES[@]}"; do
	SEARCH="${SEARCHES[$INDEX]}"
	REPLACE="${REPLACES[$INDEX]}"
	CLEAR_CACHE=false

	if [[ "$INDEX" -eq "$LAST_INDEX" ]]; then
		CLEAR_CACHE=true
	fi

	echo "Replacing '$SEARCH' with '$REPLACE'."

	if ! wait_for_environment_unblocked "$KINSTA_API_URL" "$KINSTA_API_KEY" "$SITE_ID" \
		"$ENVIRONMENT_ID" 60 15 "$SCRATCH_DIR/kinsta-envs-blocked.json"; then
		exit 3
	fi

	PAYLOAD="$(jq -n \
		--arg environment_id "$ENVIRONMENT_ID" \
		--arg search "$SEARCH" \
		--arg replace "$REPLACE" \
		--argjson is_clear_cache "$CLEAR_CACHE" \
		'{environment_id: $environment_id, search: $search, replace: $replace, perform_replacement: true, is_clear_cache: $is_clear_cache}')"

	STATUS_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$RESPONSE_FILE" \
		--request POST \
		--header "$KINSTA_AUTH_HEADER" \
		--header "Content-Type: application/json" \
		--data "$PAYLOAD" \
		"$KINSTA_API_URL/sites/tools/search-and-replace")" || true

	if [[ "$STATUS_CODE" != "202" && "$STATUS_CODE" != "200" ]]; then
		cat "$RESPONSE_FILE" >&2 || true
		echo "Failed to start search-replace of '$SEARCH' (HTTP $STATUS_CODE)" >&2
		exit 4
	fi

	OPERATION_ID="$(jq -r '.operation_id // empty' "$RESPONSE_FILE")"

	if [[ -z "$OPERATION_ID" ]]; then
		echo "Search-replace of '$SEARCH' finished without an operation to poll."
		continue
	fi

	if ! poll_kinsta_operation "$KINSTA_API_URL" "$KINSTA_API_KEY" "$OPERATION_ID" \
		"$MAX_ATTEMPTS" "$SLEEP_SECONDS" "$OP_FILE"; then
		exit 5
	fi
done

if ! wait_for_environment_unblocked "$KINSTA_API_URL" "$KINSTA_API_KEY" "$SITE_ID" \
	"$ENVIRONMENT_ID" 60 15 "$SCRATCH_DIR/kinsta-envs-blocked.json"; then
	exit 6
fi

echo "Search-replace finished."
