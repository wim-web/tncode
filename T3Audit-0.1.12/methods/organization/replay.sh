#!/usr/bin/env bash
set -euo pipefail

audit_root="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
fixture="$(cd -- "${1:?Pass the launched desktop fixture directory}" && pwd -P)"
: "${T3_AUDIT_OUTPUT:?Set T3_AUDIT_OUTPUT to a new absolute receipt directory}"
[[ "$T3_AUDIT_OUTPUT" = /* && ! -e "$T3_AUDIT_OUTPUT" ]]
mkdir "$T3_AUDIT_OUTPUT"
export T3_AUDIT_OUTPUT

drive() { node "$audit_root/methods/drive.mjs" "$fixture" "$@"; }
press() { node "$audit_root/methods/organization/press.mjs" "$fixture" "$@"; }
palette() { drive key Meta+k wait 250 type "$1" wait 450 "${@:2}"; }

drive brief > /dev/null
fixture_pid=$(cat "$fixture/fixture.pid")
stop_fixture() {
  [[ "$(cat "$fixture/fixture.pid")" = "$fixture_pid" ]] || return 1
  drive quit || true
  for signal in TERM KILL; do
    local listener
    listener=$(/usr/sbin/lsof -nP -a -p "$fixture_pid" -iTCP:47861 -sTCP:LISTEN) || return 0
    [[ "$listener" = *127.0.0.1:47861* && "$(cat "$fixture/fixture.pid")" = "$fixture_pid" ]] || return 1
    kill "-$signal" "$fixture_pid"
    sleep 1
  done
}
trap stop_fixture EXIT

project=$(mktemp -d /private/tmp/t3-organization-project.XXXXXXXX)
project_name=${project##*/}
git -C "$project" init -q -b main
git -C "$project" config user.name 'Organization Fixture'
git -C "$project" config user.email 'organization@example.invalid'
git -C "$project" config commit.gpgsign false
git -C "$project" config core.hooksPath /dev/null
printf 'Included baseline\n' > "$project/include.txt"
printf 'Excluded baseline\n' > "$project/exclude.txt"
git -C "$project" add include.txt exclude.txt
git -C "$project" commit -qm 'Organization audit baseline'
printf 'Selected change\n' >> "$project/include.txt"
printf 'Unselected change\n' >> "$project/exclude.txt"
git -C "$project" add include.txt exclude.txt
printf 'Worktree-only excluded change\n' >> "$project/exclude.txt"

thread='fixture stream organization audit'
title='Organization Lifecycle Audit'
drive click 'label=Projects' click 'text=Add project' click 'text=Local folder' \
  key Meta+a type "$project/" key Enter wait 600 \
  click 'label=Message New thread' type "$thread" click 'label=Submit message' \
  waitText 'Fixture complete.' wait 650
drive click "label=Message $thread" type 'fixture resume cobalt-bird-77' \
  click 'label=Submit message' waitText 'Fixture thread continued' wait 2800 \
  key Meta+f fill "input[aria-label='Find in thread']" 'Second delta' wait 450 \
  save 01-find-first click 'label=Next match' wait 300 save 02-find-next key Escape
drive click "label=New thread in $project_name" wait 450 click 'label=Search threads' \
  type 'cobalt-bird-77' wait 550 save 03-history-search key Enter wait 500 save 04-history-result
drive click "label=New thread in $project_name" wait 450
palette 'cobalt-bird-77' save 05-palette-search key Enter wait 550 save 06-palette-result key Escape

palette 'Pin thread' save 08-pin-action click 'text=Pin thread' wait 500 save 09-pinned
palette 'Unpin thread' save 10-unpin-action click 'text=Unpin thread' wait 500 save 11-unpinned
palette 'Settle thread' save 12-settle-action click 'text=Settle thread' wait 550 save 13-settled
drive click "label=Message $thread" type 'fixture stream organization reactivation' \
  click 'label=Submit message' waitText Working save 14-reactivating wait 3000 save 15-reactivated
drive click 'label=Fork from this response' waitText 'Forked from conversation' wait 400 \
  save 16-fork-outcome click "label=Message $thread fork" \
  type 'fixture resume organization fork follow-up' click 'label=Submit message' \
  waitText 'Started a fresh session with its history.' wait 800 save 17-fork-followup \
  click 'label=Open source conversation' wait 500 save 18-fork-source-link

press button "$thread, $project_name" F2
drive save 07-rename-input fill 'label=Thread title' "$title" key Enter wait 400 save 07-renamed
drive click "label=Message $title" type 'fixture interrupt organization hold' click 'label=Submit message' \
  waitText 'Fixture is waiting for Stop.' click "label=Message $title" \
  type 'fixture stream organization queued deletion' key Meta+Enter wait 350 save 19-queued \
  click 'label=Edit queued message' wait 250 save 20-queue-edit key End type ' discard-me' \
  click 'label=Cancel editing queued message' wait 200 save 21-queue-edit-canceled \
  click 'label=Edit queued message' key End type ' updated' click 'label=Update queued message' \
  wait 275 save 22-queue-updated click 'label=Remove queued message' wait 350 save 23-queue-removed \
  click "label=Message $title" type 'fixture stream organization steer attempt' \
  click 'label=Steer message' wait 1200 save 24-steer-outcome wait 6000 save 25-steer-later \
  click 'label=Stop generation' wait 600 save 26-stopped

palette 'Archive thread' save 27-archive-action click 'text=Archive thread' wait 450 save 28-archived
palette 'Archived threads' click 'text=Archived threads' wait 600 save 29-archive-list \
  click "label=Unarchive $title" wait 450 save 30-archive-restored click 'label=Close' wait 300 \
  click "label=$title, $project_name" wait 450 save 31-restored-history \
  click 'label=Toggle thread details panel' wait 400 save 32-details

{
  printf '%s\n' '$ git rev-parse --short HEAD'
  git -C "$project" rev-parse --short HEAD
  printf '%s\n' '$ git remote'
  git -C "$project" remote
  printf '%s\n' '$ git status --short'
  git -C "$project" status --short
  printf '%s\n' '$ git diff --cached --no-ext-diff'
  git -C "$project" diff --cached --no-ext-diff
  printf '%s\n' '$ git diff --no-ext-diff'
  git -C "$project" diff --no-ext-diff
} > "$T3_AUDIT_OUTPUT/34-git-before.txt"

drive click 'text=Commit' waitText 'T3 Turn Fixture supports only app-server' save 33-commit-all \
  click 'label=Git action options' wait 350 save 35-git-options click "[role=menuitem]:has-text('Commit')" \
  wait 400 save 36-commit-dialog click 'text=Edit' click 'label=Include exclude.txt' \
  fill "textarea[placeholder='Leave empty to auto-generate']" 'Commit selected organization fixture file' \
  save 37-commit-selected click "[role=dialog]:has-text('Commit changes') button:text-is('Commit')" \
  waitText 'Commit selected organization fixture file' wait 500 save 38-commit-result

{
  printf '%s\n' '$ git show --format=oneline HEAD'
  git -C "$project" show --format=oneline --no-ext-diff HEAD
  printf '%s\n' '$ git status --short'
  git -C "$project" status --short
  printf '%s\n' '$ git diff --cached --no-ext-diff'
  git -C "$project" diff --cached --no-ext-diff
  printf '%s\n' '$ git diff --no-ext-diff'
  git -C "$project" diff --no-ext-diff
} > "$T3_AUDIT_OUTPUT/39-git-after.txt"
[[ "$(git -C "$project" diff-tree --no-commit-id --name-only -r HEAD)" = include.txt ]]
[[ "$(git -C "$project" status --short)" = ' M exclude.txt' ]]
[[ "$(git -C "$project" show :exclude.txt)" = 'Excluded baseline' ]]
[[ "$(cat "$project/exclude.txt")" = $'Excluded baseline\nUnselected change\nWorktree-only excluded change' ]]

drive click 'label=Toggle thread details panel'
palette 'Scheduled tasks' click 'text=Scheduled tasks' wait 550 click 'text=New task' \
  wait 400 save 40-schedule-editor click 'text=New thread each run' \
  click 'text=One thread, continuing the conversation' \
  click "button[role=combobox]:has-text('Audit Project')" \
  click "[role=option]:has-text('$project_name')" click 'label=Destination thread' wait 250 \
  click "[role=option]:has-text('$title')" fill "input[placeholder='e.g. Check for Sentry issues']" \
  'Organization audit scheduled draft' fill "textarea[placeholder='What should the agent do each time this runs?']" \
  'fixture stream organization schedule' wait 250 save 41-schedule-filled click 'text=Cancel' \
  waitText 'No scheduled tasks' save 42-schedule-canceled click 'label=Close'
