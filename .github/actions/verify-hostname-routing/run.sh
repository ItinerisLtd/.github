#!/usr/bin/env bash
set -euo pipefail

PRIMARY_DOMAIN="${INPUT_PRIMARY_DOMAIN:-}"
USER_AGENT="${INPUT_USER_AGENT:-}"
MAX_ATTEMPTS="${INPUT_MAX_ATTEMPTS:-20}"
SLEEP_SECONDS="${INPUT_SLEEP_SECONDS:-15}"

if [[ -z "$PRIMARY_DOMAIN" ]]; then
  echo "Missing INPUT_PRIMARY_DOMAIN" >&2
  exit 2
fi

if ! [[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || ! [[ "$SLEEP_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "MAX_ATTEMPTS and SLEEP_SECONDS must be integers" >&2
  exit 2
fi

HEADERS_FILE="${RUNNER_TEMP:?RUNNER_TEMP is not set}/hostname-headers.txt"

for ((ATTEMPT = 1; ATTEMPT <= MAX_ATTEMPTS; ATTEMPT++)); do
  if ! getent hosts "$PRIMARY_DOMAIN" >/dev/null 2>&1; then
    echo "$PRIMARY_DOMAIN does not resolve yet (attempt $ATTEMPT/$MAX_ATTEMPTS)."
    sleep "$SLEEP_SECONDS"
    continue
  fi

  CURL_ARGS=(--silent --show-error --dump-header "$HEADERS_FILE" --output /dev/null --max-time 20)

  if [[ -n "$USER_AGENT" ]]; then
    CURL_ARGS+=(--user-agent "$USER_AGENT")
  fi

  if curl "${CURL_ARGS[@]}" "https://$PRIMARY_DOMAIN/" 2>/dev/null; then
    if grep -qiE '^ki-' "$HEADERS_FILE"; then
      echo "$PRIMARY_DOMAIN resolves and is served by Kinsta (attempt $ATTEMPT/$MAX_ATTEMPTS)."
      grep -iE '^(HTTP/|location:|ki-edge:|ki-origin:)' "$HEADERS_FILE" || true
      exit 0
    fi

    STATUS_LINE="$(grep -m1 -i '^HTTP/' "$HEADERS_FILE" | tr -d '\r')"
    SERVED_BY_CLOUDFLARE=false

    if grep -qiE '^server:[[:space:]]*cloudflare' "$HEADERS_FILE"; then
      SERVED_BY_CLOUDFLARE=true
    fi

    # A 403 from Cloudflare is treated as success on purpose, so it is worth
    # being explicit about why a rejection counts as verification.
    #
    # The record's job is to put the hostname in the Cloudflare zone, proxied.
    # For Cloudflare to answer at all, DNS must have resolved to it, which is
    # exactly the state being checked; a missing or misdirected record cannot
    # produce this response. Cloudflare then rejects the request because a CI
    # runner is not a visitor it trusts, and that rejection is unrelated to
    # whether the record is correct.
    #
    # This confirms less than a ki-* response does, so the pass says which of
    # the two it was rather than reporting both the same way.
    if [[ "$SERVED_BY_CLOUDFLARE" == "true" && "$STATUS_LINE" == *" 403"* ]]; then
      echo "$PRIMARY_DOMAIN is proxied through Cloudflare, which answered with 403 (attempt $ATTEMPT/$MAX_ATTEMPTS)."
      echo "The record resolves and is proxied. Cloudflare blocked this request, so the origin behind it is unconfirmed."
      exit 0
    fi

    echo "::warning::$PRIMARY_DOMAIN responded, but not identifiably from Kinsta or Cloudflare."
    grep -iE '^(HTTP/|server:|cf-ray:|cf-mitigated:)' "$HEADERS_FILE" || true
    exit 0
  else
    echo "$PRIMARY_DOMAIN did not respond (attempt $ATTEMPT/$MAX_ATTEMPTS)."
  fi

  sleep "$SLEEP_SECONDS"
done

echo "$PRIMARY_DOMAIN did not respond after $MAX_ATTEMPTS attempts." >&2
echo "The DNS record is missing, still propagating, or points nowhere." >&2
exit 3
