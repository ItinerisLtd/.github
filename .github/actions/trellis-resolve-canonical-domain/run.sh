#!/usr/bin/env bash
set -euo pipefail

WORDPRESS_SITES_FILE="${INPUT_WORDPRESS_SITES_FILE:-}"
BASE_DOMAIN="${INPUT_BASE_DOMAIN:-}"

if [[ -z "$WORDPRESS_SITES_FILE" || -z "$BASE_DOMAIN" ]]; then
  echo "Missing required input(s) for domain resolution" >&2
  exit 2
fi

if [[ ! -f "$WORDPRESS_SITES_FILE" ]]; then
  echo "$WORDPRESS_SITES_FILE does not exist. Trellis has no wordpress_sites definition for this environment." >&2
  exit 1
fi

SITES_COUNT="$(yq eval '.wordpress_sites | length' "$WORDPRESS_SITES_FILE")"

if [[ "$SITES_COUNT" == "0" ]]; then
  echo "No wordpress_sites defined in $WORDPRESS_SITES_FILE" >&2
  exit 1
fi

if [[ "$SITES_COUNT" != "1" ]]; then
  SITE_NAMES="$(yq eval '.wordpress_sites | keys | join(", ")' "$WORDPRESS_SITES_FILE")"
  echo "Expected exactly one top-level wordpress_sites key in $WORDPRESS_SITES_FILE, found $SITES_COUNT: $SITE_NAMES. Multisite Trellis configs are not supported by this workflow." >&2
  exit 1
fi

SITE_NAME="$(yq eval '.wordpress_sites | keys | .[0]' "$WORDPRESS_SITES_FILE")"
HOSTS_COUNT="$(yq eval '.wordpress_sites | to_entries | .[0].value.site_hosts | length' "$WORDPRESS_SITES_FILE")"

if [[ "$HOSTS_COUNT" == "0" ]]; then
  echo "site '$SITE_NAME' in $WORDPRESS_SITES_FILE has no site_hosts entries" >&2
  exit 1
fi

if [[ "$HOSTS_COUNT" -gt 1 ]]; then
  echo "site_hosts for '$SITE_NAME' ($HOSTS_COUNT entries):" >&2
  INDEX=0
  while IFS= read -r HOST; do
    MARKER=""
    if [[ "$INDEX" -eq 0 ]]; then
      MARKER="  <- using this one (site_hosts[0])"
    fi
    echo "  [$INDEX] $HOST$MARKER" >&2
    INDEX=$((INDEX + 1))
  done < <(yq eval '.wordpress_sites | to_entries | .[0].value.site_hosts[].canonical // "<no canonical>"' "$WORDPRESS_SITES_FILE")
fi

PRIMARY_DOMAIN="$(yq eval '.wordpress_sites | to_entries | .[0].value.site_hosts[0].canonical // ""' "$WORDPRESS_SITES_FILE")"

if [[ -z "$PRIMARY_DOMAIN" ]]; then
  echo "site_hosts[0] in $WORDPRESS_SITES_FILE has no 'canonical' key" >&2
  exit 1
fi

if [[ "$PRIMARY_DOMAIN" != "${PRIMARY_DOMAIN,,}" ]]; then
  echo "Resolved domain '$PRIMARY_DOMAIN' from $WORDPRESS_SITES_FILE is not lowercase." >&2
  exit 1
fi

if ! [[ "$PRIMARY_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
  echo "Resolved domain '$PRIMARY_DOMAIN' from $WORDPRESS_SITES_FILE is not a valid hostname." >&2
  exit 1
fi

if [[ "$PRIMARY_DOMAIN" != *".$BASE_DOMAIN" ]]; then
  echo "Resolved domain '$PRIMARY_DOMAIN' from $WORDPRESS_SITES_FILE does not end with '.$BASE_DOMAIN'. Refusing to attach what looks like a real production/client hostname to a disposable Kinsta environment." >&2
  exit 1
fi

echo "PRIMARY_DOMAIN=$PRIMARY_DOMAIN" >>"$GITHUB_OUTPUT"
