#!/usr/bin/env bash

poll_kinsta_operation() {
  local API_URL="$1"
  local API_KEY="$2"
  local OPERATION_ID="$3"
  local MAX_ATTEMPTS="$4"
  local SLEEP_SECONDS="$5"
  local OP_FILE="$6"

  local ATTEMPT
  local HTTP_CODE
  local BODY_STATUS
  local BODY_MESSAGE
  local STATE
  local LAST_REPORT=''
  local SERVER_ERRORS=0
  local MAX_SERVER_ERRORS=5
  local SEEN_OPERATION='false'
  local NOT_FOUND_GRACE_ATTEMPTS=8

  sleep "$SLEEP_SECONDS"

  for ((ATTEMPT = 1; ATTEMPT <= MAX_ATTEMPTS; ATTEMPT++)); do
    HTTP_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$OP_FILE" \
      --header "Authorization: Bearer ${API_KEY}" \
      "$API_URL/operations/$OPERATION_ID")" || true

    BODY_STATUS="$(jq -r 'if (.status | type) == "number" then .status else empty end' "$OP_FILE" 2>/dev/null || true)"
    BODY_MESSAGE="$(jq -r '.data.message // .message // empty' "$OP_FILE" 2>/dev/null || true)"
    STATE="${BODY_STATUS:-$HTTP_CODE}"

    if [[ "$LAST_REPORT" != "$STATE $BODY_MESSAGE" ]]; then
      echo "Operation $OPERATION_ID: http=$HTTP_CODE state=$STATE ${BODY_MESSAGE:+($BODY_MESSAGE)}"
      LAST_REPORT="$STATE $BODY_MESSAGE"
    fi

    case "$STATE" in
      200)
        echo "Operation $OPERATION_ID finished (attempt $ATTEMPT/$MAX_ATTEMPTS)."
        return 0
        ;;
      202)
        SEEN_OPERATION='true'
        SERVER_ERRORS=0
        ;;
      500)
        cat "$OP_FILE" >&2 || true
        echo "Operation $OPERATION_ID failed: ${BODY_MESSAGE:-no message}" >&2
        return 1
        ;;
      404)
        if [[ "$SEEN_OPERATION" == "false" && "$ATTEMPT" -le "$NOT_FOUND_GRACE_ATTEMPTS" ]]; then
          echo "Operation $OPERATION_ID not registered yet (attempt $ATTEMPT/$NOT_FOUND_GRACE_ATTEMPTS)."
        else
          cat "$OP_FILE" >&2 || true
          echo "Operation $OPERATION_ID does not exist or failed on initialization" >&2
          return 1
        fi
        ;;
      502 | 503 | 504)
        SERVER_ERRORS=$((SERVER_ERRORS + 1))
        echo "::warning::Gateway error polling $OPERATION_ID (state $STATE, $SERVER_ERRORS/$MAX_SERVER_ERRORS)" >&2
        if [[ "$SERVER_ERRORS" -ge "$MAX_SERVER_ERRORS" ]]; then
          cat "$OP_FILE" >&2 || true
          echo "Giving up after $SERVER_ERRORS consecutive gateway errors" >&2
          return 1
        fi
        ;;
      *)
        cat "$OP_FILE" >&2 || true
        echo "Unexpected state $STATE polling operation $OPERATION_ID" >&2
        return 1
        ;;
    esac

    sleep "$SLEEP_SECONDS"
  done

  cat "$OP_FILE" >&2 || true
  echo "Timed out waiting for operation $OPERATION_ID after $MAX_ATTEMPTS attempts" >&2
  return 1
}

wait_for_environment_unblocked() {
  local API_URL="$1"
  local API_KEY="$2"
  local SITE_ID="$3"
  local ENV_ID="$4"
  local MAX_ATTEMPTS="$5"
  local SLEEP_SECONDS="$6"
  local ENVS_FILE="$7"

  local ATTEMPT
  local HTTP_CODE
  local BLOCKED

  for ((ATTEMPT = 1; ATTEMPT <= MAX_ATTEMPTS; ATTEMPT++)); do
    HTTP_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$ENVS_FILE" \
      --header "Authorization: Bearer ${API_KEY}" \
      "$API_URL/sites/$SITE_ID/environments")" || true

    if [[ "$HTTP_CODE" != "200" ]]; then
      cat "$ENVS_FILE" >&2 || true
      echo "Unable to read environments while waiting for $ENV_ID (HTTP $HTTP_CODE)" >&2
      return 1
    fi

    BLOCKED="$(jq -r --arg id "$ENV_ID" \
      '[.site.environments[]? | select(.id == $id) | .is_blocked] | .[0] // false' "$ENVS_FILE")"

    if [[ "$BLOCKED" != "true" ]]; then
      return 0
    fi

    echo "Environment $ENV_ID is blocked by another process (attempt $ATTEMPT/$MAX_ATTEMPTS)."
    sleep "$SLEEP_SECONDS"
  done

  echo "Timed out waiting for environment $ENV_ID to stop being blocked" >&2
  return 1
}

fetch_environments() {
  local API_URL="$1"
  local API_KEY="$2"
  local SITE_ID="$3"
  local OUT_FILE="$4"
  local HTTP_CODE

  HTTP_CODE="$(curl --silent --show-error --write-out '%{http_code}' --output "$OUT_FILE" \
    --header "Authorization: Bearer ${API_KEY}" \
    "$API_URL/sites/$SITE_ID/environments")" || true

  if [[ "$HTTP_CODE" != "200" ]]; then
    cat "$OUT_FILE" >&2 || true
    echo "Unable to read environments for site $SITE_ID (HTTP $HTTP_CODE)" >&2
    return 1
  fi
}

wait_for_primary_domain() {
  local API_URL="$1"
  local API_KEY="$2"
  local SITE_ID="$3"
  local ENV_ID="$4"
  local DOMAIN_ID="$5"
  local MAX_ATTEMPTS="$6"
  local SLEEP_SECONDS="$7"
  local ENVS_FILE="$8"

  local ATTEMPT
  local CURRENT

  for ((ATTEMPT = 1; ATTEMPT <= MAX_ATTEMPTS; ATTEMPT++)); do
    if fetch_environments "$API_URL" "$API_KEY" "$SITE_ID" "$ENVS_FILE"; then
      CURRENT="$(jq -r --arg env "$ENV_ID" \
        '[.site.environments[]? | select(.id == $env) | .primaryDomain.id // empty] | .[0] // empty' "$ENVS_FILE")"

      if [[ "$CURRENT" == "$DOMAIN_ID" ]]; then
        echo "Primary domain confirmed as $DOMAIN_ID (attempt $ATTEMPT/$MAX_ATTEMPTS)."
        return 0
      fi
    fi

    echo "Primary domain not updated yet (attempt $ATTEMPT/$MAX_ATTEMPTS)."
    sleep "$SLEEP_SECONDS"
  done

  echo "Primary domain was still not $DOMAIN_ID after $MAX_ATTEMPTS attempts" >&2
  return 1
}
