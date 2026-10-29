#!/usr/bin/env bash
set -euo pipefail

WORDPRESS_SITES_FILE="${INPUT_WORDPRESS_SITES_FILE:-}"
SOURCE_WORDPRESS_SITES_FILE="${INPUT_SOURCE_WORDPRESS_SITES_FILE:-}"
BASE_DOMAIN="${INPUT_BASE_DOMAIN:-}"

if [[ -z "$WORDPRESS_SITES_FILE" || -z "$BASE_DOMAIN" ]]; then
	echo "Missing required input(s) for domain resolution" >&2
	exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
	echo "yq is not installed on this runner. This action requires mikefarah/yq (https://github.com/mikefarah/yq), which ships preinstalled on GitHub-hosted ubuntu-latest runners." >&2
	exit 2
fi

if ! yq --version 2>&1 | grep -q "mikefarah/yq"; then
	echo "The 'yq' on PATH is not mikefarah/yq (https://github.com/mikefarah/yq). This action requires that implementation's 'yq eval' syntax, not the Python kislyuk/yq tool of the same name." >&2
	exit 2
fi

load_canonicals() {
	local FILE="$1"
	local -n CANONICALS="$2"
	local SITES_COUNT
	local SITE_NAMES
	local SITE_NAME
	local INDEX

	if [[ ! -f "$FILE" ]]; then
		echo "$FILE does not exist. Trellis has no wordpress_sites definition for this environment." >&2
		exit 1
	fi

	SITES_COUNT="$(yq eval '.wordpress_sites | length' "$FILE")"

	if [[ "$SITES_COUNT" == "0" ]]; then
		echo "No wordpress_sites defined in $FILE" >&2
		exit 1
	fi

	if [[ "$SITES_COUNT" != "1" ]]; then
		SITE_NAMES="$(yq eval '.wordpress_sites | keys | join(", ")' "$FILE")"
		echo "Expected exactly one top-level wordpress_sites key in $FILE, found $SITES_COUNT: $SITE_NAMES. Each key is a separate WordPress install, which needs its own Kinsta environment. A multisite network is one key with one site_hosts entry per site." >&2
		exit 1
	fi

	SITE_NAME="$(yq eval '.wordpress_sites | keys | .[0]' "$FILE")"
	mapfile -t CANONICALS < <(yq eval '.wordpress_sites | to_entries | .[0].value.site_hosts[]? | .canonical // ""' "$FILE")

	if [[ "${#CANONICALS[@]}" -eq 0 ]]; then
		echo "site '$SITE_NAME' in $FILE has no site_hosts entries" >&2
		exit 1
	fi
}

require_canonicals() {
	local FILE="$1"
	shift
	local DOMAINS=("$@")
	local INDEX

	for INDEX in "${!DOMAINS[@]}"; do
		if [[ -z "${DOMAINS[$INDEX]}" ]]; then
			echo "site_hosts[$INDEX] in $FILE has no 'canonical' key" >&2
			exit 1
		fi
	done
}

validate_hostname() {
	local FILE="$1"
	local DOMAIN="$2"
	local LABELS
	local LABEL

	if [[ "$DOMAIN" != "${DOMAIN,,}" ]]; then
		echo "Resolved domain '$DOMAIN' from $FILE is not lowercase." >&2
		exit 1
	fi

	if ! [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
		echo "Resolved domain '$DOMAIN' from $FILE is not a valid hostname." >&2
		exit 1
	fi

	if ((${#DOMAIN} > 253)); then
		echo "Resolved domain '$DOMAIN' from $FILE is longer than the 253-character DNS name limit." >&2
		exit 1
	fi

	IFS='.' read -ra LABELS <<<"$DOMAIN"
	for LABEL in "${LABELS[@]}"; do
		if ((${#LABEL} > 63)); then
			echo "Resolved domain '$DOMAIN' from $FILE has label '$LABEL' longer than the 63-character DNS label limit." >&2
			exit 1
		fi
	done
}

validate_unique() {
	local FILE="$1"
	shift
	local -A SEEN=()
	local DOMAIN

	for DOMAIN in "$@"; do
		if [[ -n "${SEEN[$DOMAIN]:-}" ]]; then
			echo "Domain '$DOMAIN' is listed more than once in $FILE" >&2
			exit 1
		fi
		SEEN[$DOMAIN]=1
	done
}

TARGET_DOMAINS=()
load_canonicals "$WORDPRESS_SITES_FILE" TARGET_DOMAINS
MULTISITE="$(yq eval '.wordpress_sites | to_entries | .[0].value.multisite.enabled // false' "$WORDPRESS_SITES_FILE")"

if [[ "$MULTISITE" != "true" && "${#TARGET_DOMAINS[@]}" -gt 1 ]]; then
	echo "site_hosts (${#TARGET_DOMAINS[@]} entries), multisite is not enabled so only site_hosts[0] is used:" >&2
	for INDEX in "${!TARGET_DOMAINS[@]}"; do
		echo "  [$INDEX] ${TARGET_DOMAINS[$INDEX]:-<no canonical>}" >&2
	done
	TARGET_DOMAINS=("${TARGET_DOMAINS[0]}")
fi

require_canonicals "$WORDPRESS_SITES_FILE" "${TARGET_DOMAINS[@]}"
validate_unique "$WORDPRESS_SITES_FILE" "${TARGET_DOMAINS[@]}"

for DOMAIN in "${TARGET_DOMAINS[@]}"; do
	validate_hostname "$WORDPRESS_SITES_FILE" "$DOMAIN"

	if [[ "$DOMAIN" != *".$BASE_DOMAIN" ]]; then
		echo "Resolved domain '$DOMAIN' from $WORDPRESS_SITES_FILE does not end with '.$BASE_DOMAIN'. Refusing to attach what looks like a real production/client hostname to a disposable Kinsta environment." >&2
		exit 1
	fi
done

PRIMARY_DOMAIN="${TARGET_DOMAINS[0]}"
ADDITIONAL_DOMAINS=("${TARGET_DOMAINS[@]:1}")

if [[ "${#ADDITIONAL_DOMAINS[@]}" -gt 0 ]]; then
	echo "site_hosts (${#TARGET_DOMAINS[@]} entries):" >&2
	echo "  [0] $PRIMARY_DOMAIN  <- primary" >&2
	for INDEX in "${!ADDITIONAL_DOMAINS[@]}"; do
		echo "  [$((INDEX + 1))] ${ADDITIONAL_DOMAINS[$INDEX]}  <- additional" >&2
	done
fi

PAIRS=()

if [[ -n "$SOURCE_WORDPRESS_SITES_FILE" && "${#ADDITIONAL_DOMAINS[@]}" -gt 0 ]]; then
	SOURCE_DOMAINS=()
	load_canonicals "$SOURCE_WORDPRESS_SITES_FILE" SOURCE_DOMAINS
	require_canonicals "$SOURCE_WORDPRESS_SITES_FILE" "${SOURCE_DOMAINS[@]}"
	validate_unique "$SOURCE_WORDPRESS_SITES_FILE" "${SOURCE_DOMAINS[@]}"

	if [[ "${#SOURCE_DOMAINS[@]}" -ne "${#TARGET_DOMAINS[@]}" ]]; then
		echo "$SOURCE_WORDPRESS_SITES_FILE has ${#SOURCE_DOMAINS[@]} site_hosts but $WORDPRESS_SITES_FILE has ${#TARGET_DOMAINS[@]}. The additional domains are paired by position, so both files must list the network's sites in the same order." >&2
		exit 1
	fi

	for DOMAIN in "${SOURCE_DOMAINS[@]}"; do
		validate_hostname "$SOURCE_WORDPRESS_SITES_FILE" "$DOMAIN"
	done

	SOURCE_PRIMARY="${SOURCE_DOMAINS[0]}"

	for ((INDEX = 1; INDEX < ${#SOURCE_DOMAINS[@]}; INDEX++)); do
		SEARCH="${SOURCE_DOMAINS[$INDEX]}"
		REPLACE="${TARGET_DOMAINS[$INDEX]}"

		if [[ "$SEARCH" == "$REPLACE" ]]; then
			continue
		fi

		if [[ "$SOURCE_PRIMARY" == *"$SEARCH"* ]]; then
			echo "Source domain '$SEARCH' is part of the source primary domain '$SOURCE_PRIMARY'. Replacing it would corrupt the primary domain before Kinsta rewrites it." >&2
			exit 1
		fi

		PAIRS+=("$SEARCH"$'\t'"$REPLACE")
		echo "Search-replace: $SEARCH -> $REPLACE"
	done

	for SEARCH_INDEX in "${!SOURCE_DOMAINS[@]}"; do
		for REPLACE_INDEX in "${!TARGET_DOMAINS[@]}"; do
			if [[ "$SEARCH_INDEX" -eq 0 && "$REPLACE_INDEX" -eq 0 ]]; then
				continue
			fi

			SEARCH="${SOURCE_DOMAINS[$SEARCH_INDEX]}"
			REPLACE="${TARGET_DOMAINS[$REPLACE_INDEX]}"

			if [[ "$SEARCH" != "$REPLACE" && "$REPLACE" == *"$SEARCH"* ]]; then
				echo "Source domain '$SEARCH' appears inside target domain '$REPLACE'. A later replacement would rewrite an already replaced value." >&2
				exit 1
			fi
		done
	done
fi

{
	echo "PRIMARY_DOMAIN=$PRIMARY_DOMAIN"
	echo 'ADDITIONAL_DOMAINS<<__ADDITIONAL_DOMAINS__'
	if [[ "${#ADDITIONAL_DOMAINS[@]}" -gt 0 ]]; then
		printf '%s\n' "${ADDITIONAL_DOMAINS[@]}"
	fi
	echo '__ADDITIONAL_DOMAINS__'
	echo 'SEARCH_REPLACE_PAIRS<<__SEARCH_REPLACE_PAIRS__'
	if [[ "${#PAIRS[@]}" -gt 0 ]]; then
		printf '%s\n' "${PAIRS[@]}" | awk -F '\t' '{ print length($1) "\t" $0 }' | sort -rn -k1,1 | cut -f2-
	fi
	echo '__SEARCH_REPLACE_PAIRS__'
} >>"$GITHUB_OUTPUT"
