#!/usr/bin/env bash
# Post one Discord embed per commit $GH_USER pushes to a public GitHub repo
# owned by one of $REPO_OWNERS.
# The CI counterpart of the local push-watch.sh: it reads $GH_USER's public
# event feed instead of local reflogs, so it only reports commits that reached
# GitHub, and private repos never appear in that feed.
#
#   DISCORD_WEBHOOK=... bash scripts/discord-push-feed.sh   # post new pushes, advance the cursor
#   bash scripts/discord-push-feed.sh --dry-run             # print the embeds, post nothing
#
# The cursor (the last handled event id) lives in $STATE_FILE. Without one, a
# run records the newest event and posts nothing, so a lost cursor never
# replays the feed. Requires: gh (authenticated), jq, curl.

set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; fi

GH_USER="monotykamary"
# Pushes to anyone else's repo (a contributor's fork behind a PR, say) are
# skipped: that work reaches these owners' repos when the PR merges.
REPO_OWNERS=("monotykamary" "fabric-runtime")
STATE_FILE="${STATE_FILE:-.discord-push-feed/last-event-id}"
FEED_CAPACITY=300   # the public events API never returns more than this
EMBED_COLOR=5763719
MAX_SEND_ATTEMPTS=5
RATE_LIMIT_SLEEP_MAX_S=30
CURL_MAX_TIME_S=10
CURL_CONNECT_TIMEOUT_S=5
ZERO_SHA="0000000000000000000000000000000000000000"

if (( ! DRY_RUN )) && [[ -z "${DISCORD_WEBHOOK:-}" ]]; then
  echo "ERROR: DISCORD_WEBHOOK is not set." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

save_cursor() {
  (( DRY_RUN )) && return 0
  mkdir -p "$(dirname "$STATE_FILE")"
  printf '%s\n' "$1" > "$STATE_FILE"
}

is_owned() {
  local owner="${1%%/*}" allowed
  for allowed in "${REPO_OWNERS[@]}"; do
    [[ "${owner,,}" == "${allowed,,}" ]] && return 0
  done
  return 1
}

# Railway deploy repos and inloop work stay out of the channel, as in push-watch.sh.
is_excluded() {
  local name="${1,,}" branch="${2,,}"
  [[ "$name" == railway-* || "$name" == *inloop* || "$branch" == railway-* || "$branch" == *inloop* ]]
}

# post <payload>: 0 when posted or rejected as malformed (skipped, like
# push-watch's dead letter), 1 when Discord is unreachable or the webhook is
# gone, so the caller stops without advancing the cursor.
post() {
  local payload="$1" attempt http delay
  if (( DRY_RUN )); then
    jq -c '.embeds[0] | {title, description, url}' <<<"$payload"
    return 0
  fi
  for ((attempt = 1; attempt <= MAX_SEND_ATTEMPTS; attempt++)); do
    http=$(curl -sS -o "$TMP/resp" -w '%{http_code}' \
      --max-time "$CURL_MAX_TIME_S" --connect-timeout "$CURL_CONNECT_TIMEOUT_S" \
      -X POST "$DISCORD_WEBHOOK" -H 'Content-Type: application/json' \
      --data-binary "$payload" 2>/dev/null) || http="000"
    case "$http" in
      2*) return 0 ;;
      401|403|404)
        echo "::error::Discord refused the webhook (http $http); it was probably deleted or rotated." >&2
        return 1
        ;;
      429)
        delay=$(jq -r '.retry_after // 1' "$TMP/resp" 2>/dev/null) || delay=1
        [[ "$delay" =~ ^[0-9]+([.][0-9]+)?$ ]] || delay=1
        delay=$(awk -v d="$delay" -v hi="$RATE_LIMIT_SLEEP_MAX_S" 'BEGIN{i=int(d)+1; if(i>hi)i=hi; print i}')
        sleep "$delay"
        ;;
      4*)
        echo "::warning::Discord rejected an embed (http $http); skipping it." >&2
        return 0
        ;;
      *) sleep "$attempt" ;;
    esac
  done
  echo "::error::Discord kept failing after $MAX_SEND_ATTEMPTS attempts." >&2
  return 1
}

# Commits of one push as NDJSON {sha, msg}, oldest first. A new branch reports
# only its head; a force push (before is no longer an ancestor) reports nothing,
# matching push-watch.sh. Only commits $GH_USER authored or committed count, so
# merging someone else's work doesn't announce their commits as yours.
push_commits() {
  local repo="$1" before="$2" head="$3" status
  if [[ "$before" == "$ZERO_SHA" ]]; then
    gh api "repos/$repo/commits/$head" \
      --jq '{sha, msg: (.commit.message | split("\n")[0])} | tojson' 2>/dev/null || true
    return 0
  fi
  gh api "repos/$repo/compare/$before...$head" > "$TMP/compare.json" 2>/dev/null || return 0
  status=$(jq -r '.status' "$TMP/compare.json")
  [[ "$status" == "ahead" ]] || return 0
  jq -c --arg u "$GH_USER" '
    .commits[]
    | select(.author.login == $u or .committer.login == $u)
    | {sha, msg: (.commit.message | split("\n")[0])}
  ' "$TMP/compare.json"
}

# Newest first, as the API returns it.
gh api --paginate "users/$GH_USER/events/public?per_page=100" --jq '.[] | tojson' > "$TMP/events.ndjson"

newest=$(head -n 1 "$TMP/events.ndjson" | jq -r '.id // empty')
if [[ -z "$newest" ]]; then
  echo "No public events for $GH_USER."
  exit 0
fi

last=$(cat "$STATE_FILE" 2>/dev/null || true)
if [[ -z "$last" ]]; then
  save_cursor "$newest"
  echo "No cursor yet; starting from event $newest. Nothing posted."
  exit 0
fi

event_count=$(wc -l < "$TMP/events.ndjson" | tr -d ' ')
oldest=$(tail -n 1 "$TMP/events.ndjson" | jq -r '.id')
if (( event_count >= FEED_CAPACITY && oldest > last )); then
  echo "::warning::The feed rolled past the cursor; pushes between events $last and $oldest were not reported."
fi

jq -s -c --arg u "$GH_USER" --argjson last "$last" '
  map(select((.id | tonumber) > $last))
  | reverse
  | .[]
  | select(.type == "PushEvent" and .actor.login == $u and (.payload.ref | startswith("refs/heads/")))
  | {id, repo: .repo.name, branch: (.payload.ref | sub("^refs/heads/"; "")), before: .payload.before, head: .payload.head}
' "$TMP/events.ndjson" > "$TMP/pushes.ndjson"

posted=0
declare -A seen=()
while IFS= read -r push; do
  id=$(jq -r '.id' <<<"$push")
  repo=$(jq -r '.repo' <<<"$push")
  branch=$(jq -r '.branch' <<<"$push")
  name="${repo#*/}"
  if is_owned "$repo" && ! is_excluded "$name" "$branch"; then
    remote="https://github.com/$repo"
    while IFS= read -r commit; do
      [[ -n "$commit" ]] || continue
      sha=$(jq -r '.sha' <<<"$commit")
      [[ -z "${seen[$sha]+set}" ]] || continue
      seen[$sha]=1
      short="${sha:0:7}"
      payload=$(jq -nc \
        --arg name "$name" --arg url "$remote/commit/$short" --arg branch "$branch" \
        --arg short "$short" --arg remote "$remote" --argjson commit "$commit" \
        --argjson color "$EMBED_COLOR" \
        '{embeds:[{title:("📤 "+$name),url:$url,fields:[{name:"Branch",value:("`"+$branch+"`"),inline:true},{name:"Commit",value:("`"+$short+"`"),inline:true},{name:"Remote",value:$remote,inline:false}],description:$commit.msg,color:$color}]}')
      # A push left half-posted is retried whole on the next run.
      post "$payload" || exit 1
      posted=$((posted + 1))
    done < <(push_commits "$repo" "$(jq -r '.before' <<<"$push")" "$(jq -r '.head' <<<"$push")")
  fi
  save_cursor "$id"
done < "$TMP/pushes.ndjson"

save_cursor "$newest"
echo "Posted $posted commit(s) from $(wc -l < "$TMP/pushes.ndjson" | tr -d ' ') push(es); cursor at $newest."
