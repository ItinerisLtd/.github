#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="${INPUT_REPOSITORY:-}"
FILE_PATH="${INPUT_FILE_PATH:-}"
CONTENT_FILE="${INPUT_CONTENT_FILE:-}"
COMMIT_MESSAGE="${INPUT_COMMIT_MESSAGE:-}"
CHECK_NAMES="${INPUT_CHECK_NAMES:-}"
BASE_BRANCH="${INPUT_BASE_BRANCH:-}"

if [[ -z "$REPOSITORY" || -z "$FILE_PATH" || -z "$CONTENT_FILE" || -z "$COMMIT_MESSAGE" || -z "$CHECK_NAMES" ]]; then
  echo "Missing required input(s)" >&2
  exit 2
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN is not set" >&2
  exit 2
fi

if [[ ! -f "$CONTENT_FILE" ]]; then
  echo "$CONTENT_FILE does not exist." >&2
  exit 1
fi

mapfile -t CHECK_NAMES_ARRAY <<<"$CHECK_NAMES"

NON_BLANK_CHECK_NAMES=0
for NAME in "${CHECK_NAMES_ARRAY[@]}"; do
  [[ -n "$NAME" ]] && NON_BLANK_CHECK_NAMES=$((NON_BLANK_CHECK_NAMES + 1))
done

if ((NON_BLANK_CHECK_NAMES == 0)); then
  echo "CHECK_NAMES contained no non-blank entries; refusing to merge with no checks to wait for." >&2
  exit 2
fi

if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="$(gh api "repos/$REPOSITORY" --jq '.default_branch')"
fi
BASE_SHA="$(gh api "repos/$REPOSITORY/git/ref/heads/$BASE_BRANCH" --jq '.object.sha')"

BRANCH_NAME="kinsta-ssh-sync/$(basename "$FILE_PATH")-$(date +%s)"

gh api "repos/$REPOSITORY/git/refs" \
  -f ref="refs/heads/$BRANCH_NAME" \
  -f sha="$BASE_SHA" >/dev/null

EXISTING_SHA="$(gh api --method GET "repos/$REPOSITORY/contents/$FILE_PATH" -f ref="$BRANCH_NAME" --jq '.sha')"
ENCODED_CONTENT="$(base64 -w0 "$CONTENT_FILE")"

gh api --method PUT "repos/$REPOSITORY/contents/$FILE_PATH" \
  -f message="$(printf '%s\n\n[cd skip]' "$COMMIT_MESSAGE")" \
  -f content="$ENCODED_CONTENT" \
  -f sha="$EXISTING_SHA" \
  -f branch="$BRANCH_NAME" >/dev/null

PR_NUMBER="$(gh api "repos/$REPOSITORY/pulls" \
  -f title="$COMMIT_MESSAGE" \
  -f head="$BRANCH_NAME" \
  -f base="$BASE_BRANCH" \
  -f body="Automated sync of Kinsta SSH connection details. Merges automatically once checks pass." \
  --jq '.number')"

echo "Opened PR #$PR_NUMBER on $REPOSITORY"

HEAD_SHA="$(gh api "repos/$REPOSITORY/pulls/$PR_NUMBER" --jq '.head.sha')"

MAX_ATTEMPTS=60
SLEEP_SECONDS=10
ATTEMPT=0

while true; do
  ALL_PASSED=true
  CHECK_RUNS_JSON="$(gh api "repos/$REPOSITORY/commits/$HEAD_SHA/check-runs" --jq '.check_runs')"

  for NAME in "${CHECK_NAMES_ARRAY[@]}"; do
    [[ -z "$NAME" ]] && continue

    mapfile -t CONCLUSIONS < <(jq -r --arg name "$NAME" \
      '.[] | select(.name == $name) | (.conclusion // "pending")' \
      <<<"$CHECK_RUNS_JSON")

    if ((${#CONCLUSIONS[@]} == 0)); then
      ALL_PASSED=false
      continue
    fi

    for CONCLUSION in "${CONCLUSIONS[@]}"; do
      case "$CONCLUSION" in
        success | skipped) ;;
        failure | cancelled | timed_out | action_required)
          echo "Check '$NAME' concluded '$CONCLUSION' on $REPOSITORY PR #$PR_NUMBER." >&2
          exit 1
          ;;
        *)
          ALL_PASSED=false
          ;;
      esac
    done
  done

  if [[ "$ALL_PASSED" == "true" ]]; then
    break
  fi

  ATTEMPT=$((ATTEMPT + 1))
  if ((ATTEMPT >= MAX_ATTEMPTS)); then
    echo "Timed out waiting for checks on $REPOSITORY PR #$PR_NUMBER." >&2
    exit 1
  fi

  sleep "$SLEEP_SECONDS"
done

gh api --method PUT "repos/$REPOSITORY/pulls/$PR_NUMBER/merge" \
  -f merge_method="squash" \
  -f commit_title="$COMMIT_MESSAGE" \
  -f commit_message="[cd skip]" >/dev/null

gh api --method DELETE "repos/$REPOSITORY/git/refs/heads/$BRANCH_NAME" >/dev/null || true

echo "PR_NUMBER=$PR_NUMBER" >>"$GITHUB_OUTPUT"
