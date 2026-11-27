#!/usr/bin/env bash
# cspell:words argjson fdev uhead slurpfile frelease todate tostring getpath nullable
# Collects what upstream Shorebird and Flutter have shipped and compares it
# with what this fork supports. Detects and reports only; integrating an
# update is the manual promotion process (selfhost/TOOLCHAIN_PROMOTION.md).
#
#   tool/upstream_watch.sh --json
#   tool/upstream_watch.sh --report previous-state.json [--out state.json] [--changes-file changes.md]
#
# --json                 print the current state as JSON.
# --report FILE          print a Markdown summary: ours vs upstream, then every
#                        field that changed since FILE. FILE may be `{}` (a
#                        first run: nothing is listed as new).
# --out FILE             with --report, also write the current state to FILE.
# --changes-file FILE    with --report, write the "new since last check" list
#                        to FILE; the file is empty when nothing changed.
#
# Needs gh (authenticated; GH_TOKEN works), curl and jq. Exits 0 on success and
# non-zero only when an API or file could not be read.
set -euo pipefail

OURS=mml555/shorebird
UPSTREAM=shorebirdtech/shorebird
UPSTREAM_FLUTTER=shorebirdtech/flutter
UPSTREAM_UPDATER=shorebirdtech/updater
RELEASES_URL=https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json

die() {
  echo "upstream_watch: $*" >&2
  exit 1
}

# gh_api <path> [gh api args...]: stdout only; on failure die, naming the path
# and gh's own message. stderr is never mixed into the result.
gh_api() {
  local out err_file
  err_file=$(mktemp)
  if ! out=$(gh api "$@" 2>"$err_file"); then
    local msg
    msg=$(cat "$err_file")
    rm -f "$err_file"
    die "gh api $1 failed: $msg"
  fi
  rm -f "$err_file"
  printf '%s\n' "$out"
}

# gh_api_or_absent <path> [gh api args...]: like gh_api, but a genuine HTTP 404
# prints nothing and returns 0 (the thing is absent); any other failure dies.
gh_api_or_absent() {
  local out err_file
  err_file=$(mktemp)
  if out=$(gh api "$@" 2>"$err_file"); then
    rm -f "$err_file"
    printf '%s' "$out"
    return 0
  fi
  local msg
  msg=$(cat "$err_file")
  rm -f "$err_file"
  case $msg in
    *"HTTP 404"*) return 0 ;;
    *) die "gh api $1 failed: $msg" ;;
  esac
}

# newest_tag <prefix> <tag list>: the highest <prefix>X.Y.Z (no pre-releases),
# or nothing.
newest_tag() {
  local prefix=$1 tags=$2
  printf '%s\n' "$tags" | grep -E "^${prefix}[0-9]+\.[0-9]+\.[0-9]+\$" | sort -V | tail -1 || true
}

# The value of a top-level `shorebird:` key in compatibility.yaml (the first
# entry, which is the supported one; `previous:` and others follow it), with
# the trailing comment dropped.
yaml_value() {
  awk -v key="$1" '
    /^[^ #]/ { in_block = ($0 == "shorebird:"); next }
    in_block && $1 == key ":" {
      sub(/^[^:]*:[ ]*/, "")
      sub(/[ ]+#.*$/, "")
      print
      exit
    }
  ' "$2"
}

collect() {
  local tmp release cmp flutter_dev updater_head rcb branches flutter_release tags patch_tag push_tag
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  # Shorebird CLI. compare main...shorebirdtech:main has base=our main and
  # head=upstream main, so ahead_by counts upstream commits we lack.
  release=$(gh_api "repos/$UPSTREAM/releases/latest")
  cmp=$(gh_api "repos/$OURS/compare/main...shorebirdtech:main" --jq '{ahead_by, status}')

  # Shorebird's Flutter fork: no Releases, so the highest release branch
  # (plain X.Y.Z only; a -sb.N suffix is not a new Flutter release).
  branches=$(gh_api "repos/$UPSTREAM_FLUTTER/branches" --paginate --jq '.[].name')
  flutter_release=$(printf '%s\n' "$branches" |
    grep -E '^flutter_release/[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)
  [ -n "$flutter_release" ] || die "$UPSTREAM_FLUTTER has no flutter_release/X.Y.Z branch in its branch list"
  flutter_dev=$(gh_api "repos/$UPSTREAM_FLUTTER/commits/shorebird/dev")
  # A genuine 404 means the file is absent (null in the state).
  rcb=$(gh_api_or_absent -H 'Accept: application/vnd.github.raw' \
    "repos/$UPSTREAM_FLUTTER/contents/bin/internal/release-candidate-branch.version?ref=shorebird/dev" |
    tr -d '[:space:]')

  updater_head=$(gh_api "repos/$UPSTREAM_UPDATER/commits/main")
  tags=$(gh_api "repos/$UPSTREAM_UPDATER/tags" --paginate --jq '.[].name')
  patch_tag=$(newest_tag 'patch-v' "$tags")
  push_tag=$(newest_tag 'shorebird_code_push-v' "$tags")

  curl -fsS --retry 3 "$RELEASES_URL" >"$tmp/releases.json" || die "could not fetch $RELEASES_URL"

  # Ours, from main's checked-in file.
  gh_api -H 'Accept: application/vnd.github.raw' \
    "repos/$OURS/contents/selfhost/compatibility.yaml?ref=main" >"$tmp/compat.yaml"
  local k
  for k in cli_version cli_revision flutter_revision engine_revision updater_revision; do
    [ -n "$(yaml_value "$k" "$tmp/compat.yaml")" ] ||
      die "selfhost/compatibility.yaml has no shorebird.$k"
  done

  jq -n \
    --argjson release "$release" \
    --argjson cmp "$cmp" \
    --argjson fdev "$flutter_dev" \
    --argjson uhead "$updater_head" \
    --slurpfile releases "$tmp/releases.json" \
    --arg frelease "$flutter_release" \
    --arg rcb "$rcb" \
    --arg patch_tag "$patch_tag" \
    --arg push_tag "$push_tag" \
    --arg cli_version "$(yaml_value cli_version "$tmp/compat.yaml")" \
    --arg cli_revision "$(yaml_value cli_revision "$tmp/compat.yaml")" \
    --arg flutter_revision "$(yaml_value flutter_revision "$tmp/compat.yaml")" \
    --arg engine_revision "$(yaml_value engine_revision "$tmp/compat.yaml")" \
    --arg updater_revision "$(yaml_value updater_revision "$tmp/compat.yaml")" '
    def nullable: if . == "" then null else . end;
    def day: .[0:10];
    def channel($c):
      ($releases[0].current_release[$c]) as $h
      | ($releases[0].releases | map(select(.hash == $h and .channel == $c)) | first) as $r
      | if $r == null then error("Flutter \($c) hash \($h) is not in releases_linux.json") else $r end
      | { version, dart_sdk_version: (.dart_sdk_version | split(" ")[0]),
          release_date: (.release_date | day), hash };
    # Upstream names reach Markdown and an HTML comment: allow only
    # [A-Za-z0-9._/+-], so no bracket, backtick, pipe or "-->" gets through.
    def safe: walk(if type == "string" then gsub("[^A-Za-z0-9._/+-]"; "_") else . end);
    {
      generated_at: (now | todate | day),
      shorebird_cli: {
        latest_release: { tag: $release.tag_name, date: ($release.published_at | day) },
        upstream_commits_we_lack: $cmp.ahead_by,
        compare_status: $cmp.status
      },
      shorebird_flutter: {
        latest_release_branch: $frelease,
        dev: { sha: $fdev.sha, date: ($fdev.commit.committer.date | day) },
        release_candidate_branch: ($rcb | nullable)
      },
      shorebird_updater: {
        main: { sha: $uhead.sha, date: ($uhead.commit.committer.date | day) },
        latest_tag: { patch: ($patch_tag | nullable), shorebird_code_push: ($push_tag | nullable) }
      },
      flutter: { stable: channel("stable"), beta: channel("beta") },
      ours: {
        cli_version: $cli_version,
        cli_revision: $cli_revision,
        flutter_revision: $flutter_revision,
        engine_revision: $engine_revision,
        updater_revision: $updater_revision
      }
    } | safe'
}

# Only these fields notify (a comment, so an email): a new Shorebird CLI
# release, a new highest flutter_release/* branch, a new release-candidate
# version on shorebird/dev, a new updater tag in each family, and a new Flutter
# stable or beta version. Head shas, dates and the commit count appear in the
# table but never notify.
NOTIFY='["shorebird_cli.latest_release.tag","shorebird_flutter.latest_release_branch","shorebird_flutter.release_candidate_branch","shorebird_updater.latest_tag.patch","shorebird_updater.latest_tag.shorebird_code_push","flutter.stable.version","flutter.beta.version"]'

# changes <previous.json> <current.json>: Markdown bullets, one per changed
# notifying field. A previous state that is not a non-empty object (a first
# run, or a lost baseline) lists nothing; the caller decides what that means.
changes() {
  jq -r -n --slurpfile prev "$1" --slurpfile cur "$2" --argjson notify "$NOTIFY" '
    def flat: . as $r
      | [path(..) as $p | select($p | length > 0)
         | ($r | getpath($p)) as $v | select(($v | type) != "object" and ($v | type) != "array")
         | {key: ($p | map(tostring) | join(".")), value: $v}]
      | map(select(.key as $k | $notify | index($k)))
      | from_entries;
    def show($k; $v):
      if $v == null then "absent"
      else ($v | tostring) as $s
        | if   ($k == "shorebird_cli.latest_release.tag") then "[\($s)](https://github.com/shorebirdtech/shorebird/releases/tag/\($s))"
          elif ($k == "shorebird_flutter.latest_release_branch") then "[\($s)](https://github.com/shorebirdtech/flutter/tree/\($s))"
          else "`\($s)`" end
      end;
    (if ($prev[0] | type) == "object" then $prev[0] else {} end) as $pv
    | ($pv | flat) as $p | ($cur[0] | flat) as $c
    | select($p | length > 0)
    | $c | to_entries[] | . as $e
    | select((($p | has($e.key)) | not) or ($p[$e.key] != $e.value))
    | "- `\($e.key)`: " + (if ($p | has($e.key)) then show($e.key; $p[$e.key]) else "(new)" end) + " -> " + show($e.key; $e.value)
  '
}

report() {
  local prev=$1 state=$2
  jq -r '
    def sha: if . == null or . == "" then "absent" else (tostring | .[0:10]) end;
    def val: if . == null or . == "" then "absent" else tostring end;
    def stack($c): "\($c.version | val) (Dart \($c.dart_sdk_version | val), \($c.release_date | val))";
    "## Upstream watch",
    "",
    "Checked \(.generated_at). Detection only; integrating an update is the manual promotion process (`selfhost/TOOLCHAIN_PROMOTION.md`). Leave this issue open: a comment is added only when a new Shorebird CLI release, `flutter_release/*` branch, release-candidate version, updater tag or Flutter stable or beta version appears. Head commits and the commit count below are informational and never notify.",
    "",
    "| What | Ours (supported) | Upstream |",
    "| --- | --- | --- |",
    "| Shorebird CLI | `\(.ours.cli_version)` at [`\(.ours.cli_revision | sha)`](https://github.com/mml555/shorebird/commit/\(.ours.cli_revision)) | [\(.shorebird_cli.latest_release.tag)](https://github.com/shorebirdtech/shorebird/releases/tag/\(.shorebird_cli.latest_release.tag)) (\(.shorebird_cli.latest_release.date | val)) |",
    "| Upstream main commits we lack | - | \(.shorebird_cli.upstream_commits_we_lack) (compare status: \(.shorebird_cli.compare_status)) |",
    "| Shorebird Flutter fork | [`\(.ours.flutter_revision | sha)`](https://github.com/mml555/shorebird-flutter/commit/\(.ours.flutter_revision)) | release branch [\(.shorebird_flutter.latest_release_branch)](https://github.com/shorebirdtech/flutter/tree/\(.shorebird_flutter.latest_release_branch)); `shorebird/dev` [\(.shorebird_flutter.dev.sha | sha)](https://github.com/shorebirdtech/flutter/commit/\(.shorebird_flutter.dev.sha)) (\(.shorebird_flutter.dev.date | val)); candidate `\(.shorebird_flutter.release_candidate_branch | val)` |",
    "| Engine | `\(.ours.engine_revision | sha)` | - |",
    "| Updater | `\(.ours.updater_revision)` | `main` [\(.shorebird_updater.main.sha | sha)](https://github.com/shorebirdtech/updater/commit/\(.shorebird_updater.main.sha)) (\(.shorebird_updater.main.date | val)); newest tags `\(.shorebird_updater.latest_tag.patch | val)`, `\(.shorebird_updater.latest_tag.shorebird_code_push | val)` |",
    "| Flutter stable | - | \(stack(.flutter.stable)) |",
    "| Flutter beta | - | \(stack(.flutter.beta)) |"
  ' "$state"
  echo
  echo "### New since last check"
  echo
  local list
  list=$(changes "$prev" "$state") || die "could not compare against $prev"
  if [ -n "$list" ]; then
    printf '%s\n' "$list"
  else
    echo "Nothing new."
  fi
  if [ -n "${CHANGES_FILE:-}" ]; then
    if [ -n "$list" ]; then printf '%s\n' "$list" >"$CHANGES_FILE"; else : >"$CHANGES_FILE"; fi
  fi
}

mode=
prev=
OUT_FILE=
CHANGES_FILE=
while [ $# -gt 0 ]; do
  case $1 in
    --json) mode=json ;;
    --report) mode=report; prev=${2:?--report needs a previous state file}; shift ;;
    --out) OUT_FILE=${2:?--out needs a file}; shift ;;
    --changes-file) CHANGES_FILE=${2:?--changes-file needs a file}; shift ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done
[ -n "$mode" ] || die "give --json or --report <previous-state.json> (try --help)"
for tool in gh curl jq; do
  command -v "$tool" >/dev/null || die "$tool is required"
done

if [ "$mode" = json ]; then
  collect
else
  [ -f "$prev" ] || die "previous state file not found: $prev"
  jq -e . "$prev" >/dev/null || die "previous state file is not JSON: $prev"
  state_file=$(mktemp)
  trap 'rm -f "$state_file"' EXIT
  collect >"$state_file"
  [ -z "$OUT_FILE" ] || cp "$state_file" "$OUT_FILE"
  report "$prev" "$state_file"
fi
