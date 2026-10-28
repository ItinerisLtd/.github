#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=../_lib/kinsta-api.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/kinsta-api.sh"
# shellcheck source=../_lib/list.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/list.sh"

SITE_ID="${INPUT_SITE_ID:-}"
ENVIRONMENT_ID="${INPUT_ENVIRONMENT_ID:-}"
PRIMARY_DOMAIN="${INPUT_PRIMARY_DOMAIN:-}"
BASE_DOMAIN="${INPUT_BASE_DOMAIN:-}"
KINSTA_API_URL="${INPUT_KINSTA_API_URL:-}"
KINSTA_TOKEN="${INPUT_KINSTA_API_KEY:-}"

if [[ -z "$SITE_ID" || -z "$ENVIRONMENT_ID" || -z "$PRIMARY_DOMAIN" || -z "$BASE_DOMAIN" || -z "$KINSTA_API_URL" || -z "$KINSTA_TOKEN" ]]; then
	echo "Missing required input(s) for domain attachment" >&2
	exit 2
fi

read_newline_list ADDITIONAL_DOMAINS "${INPUT_ADDITIONAL_DOMAINS:-}"

for DOMAIN in "$PRIMARY_DOMAIN" "${ADDITIONAL_DOMAINS[@]}"; do
	if [[ "$DOMAIN" != *".$BASE_DOMAIN" ]]; then
		echo "Domain '$DOMAIN' does not end with '.$BASE_DOMAIN'" >&2
		exit 3
	fi
done

for DOMAIN in "${ADDITIONAL_DOMAINS[@]}"; do
	if [[ "$DOMAIN" == "$PRIMARY_DOMAIN" ]]; then
		echo "Additional domain '$DOMAIN' is the same as the primary domain" >&2
		exit 3
	fi
done

echo "Using primary domain: $PRIMARY_DOMAIN"

if [[ "${#ADDITIONAL_DOMAINS[@]}" -gt 0 ]]; then
	echo "Using additional domains: ${ADDITIONAL_DOMAINS[*]}"
fi

KINSTA_AUTH_HEADER="Authorization: Bearer ${KINSTA_TOKEN}"
SCRATCH_DIR="${RUNNER_TEMP:?RUNNER_TEMP is not set}"
DOMAINS_FILE="$SCRATCH_DIR/kinsta-domains.json"
CREATE_FILE="$SCRATCH_DIR/kinsta-domain-create.json"
OP_FILE="$SCRATCH_DIR/kinsta-domain-op.json"

lookup_domain_id() {
	local DOMAIN="$1"
	local STATUS_CODE

	STATUS_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$DOMAINS_FILE" \
		--header "$KINSTA_AUTH_HEADER" \
		"$KINSTA_API_URL/sites/environments/$ENVIRONMENT_ID/domains")" || true

	if [[ "$STATUS_CODE" != "200" ]]; then
		cat "$DOMAINS_FILE" >&2 || true
		echo "Unable to list domains for environment $ENVIRONMENT_ID (HTTP $STATUS_CODE)" >&2
		exit 4
	fi

	jq -r --arg name "$DOMAIN" \
		'[.environment.site_domains[]? | select(.name == $name) | .id] | .[0] // empty' "$DOMAINS_FILE"
}

attach_domain() {
	local DOMAIN="$1"
	local DOMAIN_ID
	local ENVS_FILE
	local OTHER_ENV
	local PAYLOAD
	local STATUS_CODE
	local OPERATION_ID
	local ATTEMPT

	DOMAIN_ID="$(lookup_domain_id "$DOMAIN")"

	if [[ -n "$DOMAIN_ID" ]]; then
		echo "Domain '$DOMAIN' is already attached."
		ATTACHED_DOMAIN_ID="$DOMAIN_ID"
		return 0
	fi

	ENVS_FILE="$SCRATCH_DIR/kinsta-envs.json"

	if ! fetch_environments "$KINSTA_API_URL" "$KINSTA_TOKEN" "$SITE_ID" "$ENVS_FILE"; then
		exit 9
	fi

	OTHER_ENV="$(jq -r --arg name "$DOMAIN" --arg env "$ENVIRONMENT_ID" '
		[ .site.environments[]?
			| select(.id != $env)
			| select(any(.domains[]?; .name == $name))
			| .name
		] | .[0] // empty
	' "$ENVS_FILE")"

	if [[ -n "$OTHER_ENV" ]]; then
		echo "Domain '$DOMAIN' is already attached to the '$OTHER_ENV' environment of this site." >&2
		echo "Detach it there first, or the environments will contend for the same hostname." >&2
		exit 10
	fi

	if ! wait_for_environment_unblocked "$KINSTA_API_URL" "$KINSTA_TOKEN" "$SITE_ID" \
		"$ENVIRONMENT_ID" 60 15 "$SCRATCH_DIR/kinsta-envs-blocked.json"; then
		exit 8
	fi

	PAYLOAD="$(jq -n --arg domain_name "$DOMAIN" \
		'{domain_name: $domain_name, setup_type: "quick"}')"

	STATUS_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$CREATE_FILE" \
		--request POST \
		--header "$KINSTA_AUTH_HEADER" \
		--header "Content-Type: application/json" \
		--data "$PAYLOAD" \
		"$KINSTA_API_URL/sites/environments/$ENVIRONMENT_ID/domains")" || true

	if [[ "$STATUS_CODE" != "202" && "$STATUS_CODE" != "200" && "$STATUS_CODE" != "201" ]]; then
		cat "$CREATE_FILE" >&2 || true
		echo "Unable to add domain '$DOMAIN' (HTTP $STATUS_CODE)" >&2
		exit 5
	fi

	OPERATION_ID="$(jq -r '.operation_id // empty' "$CREATE_FILE")"

	if [[ -n "$OPERATION_ID" ]] && ! poll_kinsta_operation \
		"$KINSTA_API_URL" "$KINSTA_TOKEN" "$OPERATION_ID" 40 15 "$OP_FILE"; then
		echo "::warning::Polling the add-domain operation for '$DOMAIN' failed; checking the domain list instead."
	fi

	for ((ATTEMPT = 1; ATTEMPT <= 10; ATTEMPT++)); do
		DOMAIN_ID="$(lookup_domain_id "$DOMAIN")"

		if [[ -n "$DOMAIN_ID" ]]; then
			break
		fi

		echo "Domain '$DOMAIN' not listed yet (attempt $ATTEMPT/10)."
		sleep 15
	done

	if [[ -z "$DOMAIN_ID" ]]; then
		echo "Unable to resolve domain id for '$DOMAIN'" >&2
		jq -c '[.environment.site_domains[]? | {id, name}]' "$DOMAINS_FILE" >&2 || true
		exit 7
	fi

	ATTACHED_DOMAIN_ID="$DOMAIN_ID"
}

attach_domain "$PRIMARY_DOMAIN"
DOMAIN_ID="$ATTACHED_DOMAIN_ID"

for DOMAIN in "${ADDITIONAL_DOMAINS[@]}"; do
	attach_domain "$DOMAIN"
done

TEMP_DOMAIN="$(jq -r '
	[ .environment.site_domains[]?
		| select(.name | endswith(".kinsta.cloud"))
		| select(.name | startswith("*.") | not)
		| .name
	] | .[0] // empty
' "$DOMAINS_FILE")"

if [[ -z "$TEMP_DOMAIN" ]]; then
	echo "Unable to find a *.kinsta.cloud temporary domain for environment $ENVIRONMENT_ID to use as the pointing target" >&2
	jq -c '[.environment.site_domains[]? | {id, name}]' "$DOMAINS_FILE" >&2 || true
	exit 12
fi

# Kinsta's environment hostname (e.g. "foo.kinsta.cloud", found above) is
# distinct from its DNS pointing target: custom domains are CNAMEd to
# "foo.hosting.kinsta.cloud" instead.
POINTING_TARGET="${TEMP_DOMAIN%.kinsta.cloud}.hosting.kinsta.cloud"

for DOMAIN in "$PRIMARY_DOMAIN" "${ADDITIONAL_DOMAINS[@]}"; do
	echo "Pointing record: $DOMAIN CNAME $POINTING_TARGET"
done

if ! wait_for_environment_unblocked "$KINSTA_API_URL" "$KINSTA_TOKEN" "$SITE_ID" \
	"$ENVIRONMENT_ID" 60 15 "$SCRATCH_DIR/kinsta-envs-blocked.json"; then
	exit 11
fi

{
	echo "PRIMARY_DOMAIN=$PRIMARY_DOMAIN"
	echo "DOMAIN_ID=$DOMAIN_ID"
	echo 'ADDITIONAL_DOMAINS<<__ADDITIONAL_DOMAINS__'
	if [[ "${#ADDITIONAL_DOMAINS[@]}" -gt 0 ]]; then
		printf '%s\n' "${ADDITIONAL_DOMAINS[@]}"
	fi
	echo '__ADDITIONAL_DOMAINS__'
} >>"$GITHUB_OUTPUT"
