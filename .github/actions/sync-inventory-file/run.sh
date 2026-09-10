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

mapfile -t RAW_CHECK_NAMES <<<"$CHECK_NAMES"

# Trim CR (from CRLF line endings) and surrounding whitespace from each
# entry, since an untrimmed name would never exact-match a real check-run
# name and the wait loop would time out even though the check is present.
CHECK_NAMES_ARRAY=()
for NAME in "${RAW_CHECK_NAMES[@]}"; do
  NAME="${NAME//$'\r'/}"
  NAME="${NAME#"${NAME%%[![:space:]]*}"}"
  NAME="${NAME%"${NAME##*[![:space:]]}"}"
  CHECK_NAMES_ARRAY+=("$NAME")
done

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

BRANCH_NAME="kinsta-ssh-sync/$(basename "$FILE_PATH")-${GITHUB_RUN_ID:?GITHUB_RUN_ID is not set}-$(date +%s)"

gh api "repos/$REPOSITORY/git/refs" \
  -f ref="refs/heads/$BRANCH_NAME" \
  -f sha="$BASE_SHA" >/dev/null

# Any failure from here on (a bad commit, a check that fails or times out, a
# merge that doesn't complete) would otherwise leave the branch and PR
# behind. Clean them up on any non-zero exit; a successful run reaches its
# own explicit exit 0 without ever hitting this trap's cleanup body.
cleanup_on_failure() {
  local exit_code=$?
  if ((exit_code != 0)); then
    if [[ -n "${PR_NUMBER:-}" ]]; then
      gh api --method PATCH "repos/$REPOSITORY/pulls/$PR_NUMBER" -f state="closed" >/dev/null 2>&1 || true
    fi
    gh api --method DELETE "repos/$REPOSITORY/git/refs/heads/$BRANCH_NAME" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup_on_failure EXIT

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
  # --paginate applies --jq once PER PAGE, so a filter that returns the
  # whole array (`.check_runs`) would yield one array per page instead of
  # one combined array. Flattening to individual objects (`.check_runs[]`)
  # means each page just contributes more objects to one flat stream; `jq
  # -s` (slurp) below reassembles that stream into a single array
  # regardless of how many pages contributed to it.
  CHECK_RUNS_JSON="$(gh api --paginate "repos/$REPOSITORY/commits/$HEAD_SHA/check-runs" --jq '.check_runs[]')"

  for NAME in "${CHECK_NAMES_ARRAY[@]}"; do
    [[ -z "$NAME" ]] && continue

    # The same head SHA can carry more than one check-run sharing this name
    # (e.g. ci.yml triggers on both push and pull_request for this branch).
    # Only the most recently created instance reflects the current state —
    # an older duplicate can be `cancelled` by a concurrency group while a
    # newer one succeeds, so treat that older run as superseded, not fatal.
    # Sort by `.id` (monotonically increasing) rather than `.started_at`: a
    # newer duplicate that is still queued has `started_at: null`, which
    # jq sorts first, not last, so sorting by start time would wrongly pick
    # an older, already-concluded run as "latest".
    LATEST_CONCLUSION="$(jq -rs --arg name "$NAME" \
      '([.[] | select(.name == $name)] | sort_by(.id) | last) as $run
       | if $run == null then "pending" else ($run.conclusion // "pending") end' \
      <<<"$CHECK_RUNS_JSON")"

    case "$LATEST_CONCLUSION" in
      success | skipped | neutral) ;;
      failure | cancelled | timed_out | action_required | stale | startup_failure)
        echo "Check '$NAME' concluded '$LATEST_CONCLUSION' on $REPOSITORY PR #$PR_NUMBER." >&2
        exit 1
        ;;
      *)
        ALL_PASSED=false
        ;;
    esac
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

MERGE_RESULT="$(gh api --method PUT "repos/$REPOSITORY/pulls/$PR_NUMBER/merge" \
  -f merge_method="squash" \
  -f commit_title="$COMMIT_MESSAGE" \
  -f commit_message="[cd skip]")"

if [[ "$(jq -r '.merged' <<<"$MERGE_RESULT")" != "true" ]]; then
  echo "Merge did not complete for $REPOSITORY PR #$PR_NUMBER: $(jq -r '.message // "unknown reason"' <<<"$MERGE_RESULT")" >&2
  exit 1
fi

gh api --method DELETE "repos/$REPOSITORY/git/refs/heads/$BRANCH_NAME" >/dev/null || true

echo "PR_NUMBER=$PR_NUMBER" >>"$GITHUB_OUTPUT"
