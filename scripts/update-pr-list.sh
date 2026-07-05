#!/usr/bin/env bash
# Refresh the README's "Open Source Contributions" PR list from live GitHub data
# and commit + push if it changed. Idempotent: no commit when nothing changes.
#
#   bash scripts/update-pr-list.sh            # regenerate, commit, push
#   bash scripts/update-pr-list.sh --dry-run  # print the would-be diff, no git ops
#
# Pulls public PRs by $GH_USER only, excluding $GH_USER's own repos (a profile
# README's "contributions" = PRs to other people's projects). Requires: gh
# (authenticated), jq, git.

set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; fi

GH_USER="monotykamary"
START_MARKER="<!-- AUTO-GENERATED:CONTRIBUTIONS:START -->"
END_MARKER="<!-- AUTO-GENERATED:CONTRIBUTIONS:END -->"
README="README.md"
VISIBLE_MERGED=20

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
README_PATH="$REPO_ROOT/$README"

# Render one NDJSON PR object as a markdown bullet: "- [title](url) — `repo`".
# Backtick + em-dash are passed via jq to dodge shell quoting/encoding issues.
render() { jq -r --arg bt '`' '"- [\(.title)](\(.url)) \u2014 \($bt)\(.repo)\($bt)"'; }

# fetch_prs <state> <ndjson_out_file>
# Writes PRs (public, excluding $GH_USER's own repos) as NDJSON, created-desc.
fetch_prs() {
  local state="$1" out="$2" page=1
  : > "$out"
  while :; do
    local batch raw_count
    batch=$(gh api "search/issues?q=is:pr+is:${state}+is:public+author:${GH_USER}&per_page=100&sort=created&order=desc&page=${page}" \
      --jq '[.items[] | {title, number, repo: (.repository_url | sub("https://api.github.com/repos/"; "")), url: .html_url, created: .created_at, merged: .pull_request.merged_at}]')
    raw_count=$(jq 'length' <<<"$batch")   # raw page size drives pagination
    batch=$(jq --arg u "$GH_USER" 'map(select(.repo | startswith($u + "/") | not))' <<<"$batch")
    jq -c '.[]' <<<"$batch" >> "$out"
    if (( raw_count < 100 )); then break; fi
    page=$((page + 1))
    if (( page > 10 )); then break; fi
  done
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if (( ! DRY_RUN )); then
  # Don't clobber uncommitted work; pull latest so we don't push stale history.
  if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    echo "ERROR: $REPO_ROOT has uncommitted changes; refusing to run. Stash or commit first." >&2
    exit 1
  fi
  git -C "$REPO_ROOT" pull --ff-only
fi

fetch_prs open   "$TMP/open.ndjson"
fetch_prs merged "$TMP/merged.ndjson"
# Deterministic sort on IMMUTABLE dates so the list only reorders when the PR
# set actually changes (not when a comment bumps updated_at): open by created
# desc, merged by merge-date desc. Ties broken by url for full determinism.
jq -s -c 'sort_by([.created, .url]) | reverse | .[]'        "$TMP/open.ndjson"   > "$TMP/open.sorted"
jq -s -c 'sort_by([(.merged // .created), .url]) | reverse | .[]' "$TMP/merged.ndjson" > "$TMP/merged.sorted"
mv "$TMP/open.sorted"   "$TMP/open.ndjson"
mv "$TMP/merged.sorted" "$TMP/merged.ndjson"
OPEN_COUNT=$(jq -s 'length' "$TMP/open.ndjson")
MERGED_COUNT=$(jq -s 'length' "$TMP/merged.ndjson")

# Build the new section content (no trailing blank line; awk's print adds one).
NEW_SEC="$TMP/new_section.txt"
{
  echo "## Open Source Contributions"
  echo
  echo "### 🔓 Open Pull Requests"
  echo
  if (( OPEN_COUNT > 0 )); then
    render < "$TMP/open.ndjson"
  else
    echo "- _No open pull requests._"
  fi
  echo
  echo "### ✅ Merged Pull Requests"
  echo
  if (( MERGED_COUNT > 0 )); then
    if (( MERGED_COUNT > VISIBLE_MERGED )); then
      head -n "$VISIBLE_MERGED" "$TMP/merged.ndjson" | render
      echo "<details>"
      echo "<summary>Show $((MERGED_COUNT - VISIBLE_MERGED)) more merged PRs</summary>"
      echo
      tail -n +$((VISIBLE_MERGED + 1)) "$TMP/merged.ndjson" | render
      echo
      echo "</details>"
    else
      render < "$TMP/merged.ndjson"
    fi
  else
    echo "- _No merged pull requests._"
  fi
} > "$NEW_SEC"

# Splice the new section between the markers into a full README copy.
grep -qF "$START_MARKER" "$README_PATH" && grep -qF "$END_MARKER" "$README_PATH" \
  || { echo "ERROR: contributions markers not found in $README_PATH" >&2; exit 1; }

awk -v start="$START_MARKER" -v end="$END_MARKER" -v sec="$NEW_SEC" '
  $0 == start { print; while ((getline l < sec) > 0) print l; close(sec); inblock=1; next }
  $0 == end   { inblock=0; print; next }
  !inblock    { print }
' "$README_PATH" > "$TMP/README.md.new"

if (( DRY_RUN )); then
  echo "Open: $OPEN_COUNT  Merged: $MERGED_COUNT"
  echo "=== diff ($README -> new) ==="
  diff -- "$README_PATH" "$TMP/README.md.new" || true
  exit 0
fi

if diff -q -- "$README_PATH" "$TMP/README.md.new" >/dev/null; then
  echo "No changes; README PR list is up to date. (Open: $OPEN_COUNT, Merged: $MERGED_COUNT)"
  exit 0
fi

cp "$TMP/README.md.new" "$README_PATH"
git -C "$REPO_ROOT" add "$README"
git -C "$REPO_ROOT" commit \
  -m "docs: update PR list with latest public open and merged contributions" \
  -m "Automated refresh via scripts/update-pr-list.sh." \
  -m "Open: $OPEN_COUNT, Merged: $MERGED_COUNT."
git -C "$REPO_ROOT" push
echo "Pushed. (Open: $OPEN_COUNT, Merged: $MERGED_COUNT)"
