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

PRIMARY_DOMAIN="$(WORDPRESS_SITES_FILE="$WORDPRESS_SITES_FILE" python3 <<'PY'
import os
import sys

import yaml

path = os.environ["WORDPRESS_SITES_FILE"]

with open(path) as f:
    document = yaml.safe_load(f) or {}

sites = document.get("wordpress_sites") or {}

if not sites:
    print(f"No wordpress_sites defined in {path}", file=sys.stderr)
    sys.exit(1)

if len(sites) != 1:
    names = ", ".join(sites.keys())
    print(
        f"Expected exactly one top-level wordpress_sites key in {path}, "
        f"found {len(sites)}: {names}. Multisite Trellis configs are not "
        "supported by this workflow.",
        file=sys.stderr,
    )
    sys.exit(1)

site_name, site = next(iter(sites.items()))
site_hosts = site.get("site_hosts") or []

if not site_hosts:
    print(f"site '{site_name}' in {path} has no site_hosts entries", file=sys.stderr)
    sys.exit(1)

if len(site_hosts) > 1:
    print(f"site_hosts for '{site_name}' ({len(site_hosts)} entries):", file=sys.stderr)
    for index, host in enumerate(site_hosts):
        marker = "  <- using this one (site_hosts[0])" if index == 0 else ""
        print(f"  [{index}] {host.get('canonical', '<no canonical>')}{marker}", file=sys.stderr)

canonical = site_hosts[0].get("canonical")

if not canonical:
    print(f"site_hosts[0] in {path} has no 'canonical' key", file=sys.stderr)
    sys.exit(1)

print(canonical)
PY
)"

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
