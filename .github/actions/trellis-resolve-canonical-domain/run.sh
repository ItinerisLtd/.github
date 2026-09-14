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

RESOLVE_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/resolve_canonical_domain.py"
PRIMARY_DOMAIN="$(python3 "$RESOLVE_SCRIPT" "$WORDPRESS_SITES_FILE")"

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
