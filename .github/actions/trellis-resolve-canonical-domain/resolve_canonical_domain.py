#!/usr/bin/env python3
"""Print the canonical primary domain from a Trellis wordpress_sites.yml file."""

import sys

import yaml


def main() -> int:
    path = sys.argv[1]

    with open(path) as f:
        document = yaml.safe_load(f) or {}

    sites = document.get("wordpress_sites") or {}

    if not sites:
        print(f"No wordpress_sites defined in {path}", file=sys.stderr)
        return 1

    if len(sites) != 1:
        names = ", ".join(sites.keys())
        print(
            f"Expected exactly one top-level wordpress_sites key in {path}, "
            f"found {len(sites)}: {names}. Multisite Trellis configs are not "
            "supported by this workflow.",
            file=sys.stderr,
        )
        return 1

    site_name, site = next(iter(sites.items()))
    site_hosts = site.get("site_hosts") or []

    if not site_hosts:
        print(f"site '{site_name}' in {path} has no site_hosts entries", file=sys.stderr)
        return 1

    if len(site_hosts) > 1:
        print(f"site_hosts for '{site_name}' ({len(site_hosts)} entries):", file=sys.stderr)
        for index, host in enumerate(site_hosts):
            marker = "  <- using this one (site_hosts[0])" if index == 0 else ""
            print(f"  [{index}] {host.get('canonical', '<no canonical>')}{marker}", file=sys.stderr)

    canonical = site_hosts[0].get("canonical")

    if not canonical:
        print(f"site_hosts[0] in {path} has no 'canonical' key", file=sys.stderr)
        return 1

    print(canonical)
    return 0


if __name__ == "__main__":
    sys.exit(main())
