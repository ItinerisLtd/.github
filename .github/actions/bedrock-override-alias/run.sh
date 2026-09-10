#!/usr/bin/env bash
set -euo pipefail

SSH_USER="${INPUT_SSH_USER:-}"
SSH_HOST="${INPUT_SSH_HOST:-}"
SSH_PORT="${INPUT_SSH_PORT:-}"
TRELLIS_ENVIRONMENT="${INPUT_TRELLIS_ENVIRONMENT:-}"
ALIAS_FILE="${INPUT_ALIAS_FILE:-}"

if [[ -z "$SSH_USER" || -z "$SSH_HOST" || -z "$SSH_PORT" || -z "$TRELLIS_ENVIRONMENT" || -z "$ALIAS_FILE" ]]; then
  echo "Missing required input(s)" >&2
  exit 2
fi

TRELLIS_ENV_NORMALISED="$(tr '[:upper:]' '[:lower:]' <<<"$TRELLIS_ENVIRONMENT")"
read -r TRELLIS_ENV_NORMALISED <<<"$TRELLIS_ENV_NORMALISED"
# Use the normalised value for every subsequent block lookup, not just the
# guard below — otherwise a caller passing e.g. "Staging" would pass the
# guard (which does normalise) but then fail to find "@staging:" in the
# file (which wouldn't).
TRELLIS_ENVIRONMENT="$TRELLIS_ENV_NORMALISED"
case "$TRELLIS_ENV_NORMALISED" in
  live | production)
    echo "Refusing to override SSH alias for '$TRELLIS_ENVIRONMENT'." >&2
    echo "This override is for non-production environments only." >&2
    exit 1
    ;;
esac

IPV4_OCTET='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
if ! [[ "$SSH_HOST" =~ ^${IPV4_OCTET}(\.${IPV4_OCTET}){3}$ ]]; then
  echo "SSH_HOST '$SSH_HOST' is not an IPv4 address." >&2
  exit 1
fi

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
  echo "SSH_PORT '$SSH_PORT' is not a number." >&2
  exit 1
fi

if ((10#$SSH_PORT < 1 || 10#$SSH_PORT > 65535)); then
  echo "SSH_PORT '$SSH_PORT' is not a valid TCP port (1-65535)." >&2
  exit 1
fi

if ! [[ "$SSH_USER" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "SSH_USER '$SSH_USER' contains unexpected characters." >&2
  exit 1
fi

if [[ ! -f "$ALIAS_FILE" ]]; then
  echo "$ALIAS_FILE does not exist." >&2
  exit 1
fi

if ! grep -qxF "@$TRELLIS_ENVIRONMENT:" "$ALIAS_FILE"; then
  echo "No '@$TRELLIS_ENVIRONMENT:' alias block found in $ALIAS_FILE." >&2
  exit 1
fi

SSH_LINE_COUNT="$(awk -v env="@$TRELLIS_ENVIRONMENT:" '
  $0 == env { in_block=1; next }
  in_block && /^@[^[:space:]]/ { in_block=0 }
  in_block && /^[[:space:]]+ssh:/ { count++ }
  END { print count+0 }
' "$ALIAS_FILE")"
if [[ "$SSH_LINE_COUNT" != "1" ]]; then
  echo "Expected exactly one 'ssh:' line in the '@$TRELLIS_ENVIRONMENT:' block of $ALIAS_FILE, found $SSH_LINE_COUNT." >&2
  exit 1
fi

NEW_SSH="$SSH_USER@$SSH_HOST:$SSH_PORT"

awk -v env="@$TRELLIS_ENVIRONMENT:" -v newssh="$NEW_SSH" '
  $0 == env { in_block=1; print; next }
  in_block && /^@[^[:space:]]/ { in_block=0 }
  in_block && match($0, /^[[:space:]]+ssh:/) {
    indent = substr($0, 1, RLENGTH - 4)
    print indent "ssh: \"" newssh "\""
    next
  }
  { print }
' "$ALIAS_FILE" >"$ALIAS_FILE.tmp"
mv "$ALIAS_FILE.tmp" "$ALIAS_FILE"

# Scope the success check to the target block specifically, not the whole
# file — otherwise a coincidentally identical ssh value already present in
# a different environment's block would mask a failed rewrite here.
BLOCK_CONTENT="$(awk -v env="@$TRELLIS_ENVIRONMENT:" '
  $0 == env { in_block=1; print; next }
  in_block && /^@[^[:space:]]/ { in_block=0 }
  in_block { print }
' "$ALIAS_FILE")"

if ! grep -qF "ssh: \"$NEW_SSH\"" <<<"$BLOCK_CONTENT"; then
  echo "Failed to set ssh alias in the '@$TRELLIS_ENVIRONMENT:' block of $ALIAS_FILE." >&2
  cat "$ALIAS_FILE" >&2
  exit 1
fi

grep -A1 -F "@$TRELLIS_ENVIRONMENT:" "$ALIAS_FILE"
