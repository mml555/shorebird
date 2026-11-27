#!/usr/bin/env bash
# cspell:words argjson fdev uhead slurpfile frelease utag todate tostring getpath
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

# gh_api <path> [gh api args...]: fail with the path named.
gh_api() {
  local out
  out=$(gh api "$@" 2>&1) || die "gh api $1 failed: $out"
  printf '%s\n' "$out"
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
  local tmp release cmp flutter_dev updater_head rcb flutter_releases
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  # Shorebird CLI. compare main...shorebirdtech:main has base=our main and
  # head=upstream main, so ahead_by counts upstream commits we lack.
  release=$(gh_api "repos/$UPSTREAM/releases/latest")
  cmp=$(gh_api "repos/$OURS/compare/main...shorebirdtech:main" --jq '{ahead_by, status}')

  # Shorebird's Flutter fork: no Releases, so the highest release branch.
  flutter_releases=$(gh_api "repos/$UPSTREAM_FLUTTER/branches" --paginate --jq '.[].name' |
    grep -E '^flutter_release/[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 || true)
  flutter_dev=$(gh_api "repos/$UPSTREAM_FLUTTER/commits/shorebird/dev")
  rcb=$(gh api -H 'Accept: application/vnd.github.raw' \
    "repos/$UPSTREAM_FLUTTER/contents/bin/internal/release-candidate-branch.version?ref=shorebird/dev" 2>/dev/null |
    tr -d '[:space:]' || true)

  updater_head=$(gh_api "repos/$UPSTREAM_UPDATER/commits/main")
  local updater_tag
  updater_tag=$(gh_api "repos/$UPSTREAM_UPDATER/tags" --paginate --jq '.[].name' | sort -V | tail -1)

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
    --arg frelease "$flutter_releases" \
    --arg rcb "$rcb" \
    --arg utag "$updater_tag" \
    --arg cli_version "$(yaml_value cli_version "$tmp/compat.yaml")" \
    --arg cli_revision "$(yaml_value cli_revision "$tmp/compat.yaml")" \
    --arg flutter_revision "$(yaml_value flutter_revision "$tmp/compat.yaml")" \
    --arg engine_revision "$(yaml_value engine_revision "$tmp/compat.yaml")" \
    --arg updater_revision "$(yaml_value updater_revision "$tmp/compat.yaml")" '
    def channel($c):
      ($releases[0].current_release[$c]) as $h
      | ($releases[0].releases | map(select(.hash == $h and .channel == $c)) | first)
      | {version, dart_sdk_version, release_date, hash};
    {
      generated_at: (now | todate),
      shorebird_cli: {
        latest_release: {
          tag: $release.tag_name,
          date: $release.published_at,
          url: $release.html_url
        },
        upstream_commits_we_lack: $cmp.ahead_by,
        compare_status: $cmp.status
      },
      shorebird_flutter: {
        latest_release_branch: $frelease,
        dev: { sha: $fdev.sha, date: $fdev.commit.committer.date },
        release_candidate_branch: $rcb
      },
      shorebird_updater: {
        main: { sha: $uhead.sha, date: $uhead.commit.committer.date },
        latest_tag: $utag
      },
      flutter: { stable: channel("stable"), beta: channel("beta") },
      ours: {
        cli_version: $cli_version,
        cli_revision: $cli_revision,
        flutter_revision: $flutter_revision,
        engine_revision: $engine_revision,
        updater_revision: $updater_revision
      }
    }'
}

# Fields that appear in the table but do not count as a change: a timestamp,
# and a commit count that moves with every upstream commit.
IGNORED='["generated_at","shorebird_cli.upstream_commits_we_lack","shorebird_cli.compare_status"]'

# changes <previous.json> <current.json>: Markdown bullets, one per changed field.
changes() {
  jq -r -n --slurpfile prev "$1" --slurpfile cur "$2" --argjson ignored "$IGNORED" '
    def flat: [paths(scalars) as $p | {key: ($p | map(tostring) | join(".")), value: getpath($p)}]
              | map(select(.key as $k | $ignored | index($k) | not))
              | from_entries;
    def link($k; $v):
      if   ($k | startswith("shorebird_cli.latest_release.tag")) then "[\($v)](https://github.com/shorebirdtech/shorebird/releases/tag/\($v))"
      elif ($k == "shorebird_flutter.latest_release_branch") then "[\($v)](https://github.com/shorebirdtech/flutter/tree/\($v))"
      elif ($k == "shorebird_flutter.dev.sha") then "[\($v[0:10])](https://github.com/shorebirdtech/flutter/commit/\($v))"
      elif ($k == "shorebird_updater.main.sha") then "[\($v[0:10])](https://github.com/shorebirdtech/updater/commit/\($v))"
      elif ($k | test("^flutter\\.(stable|beta)\\.hash$")) then "[\($v[0:10])](https://github.com/flutter/flutter/commit/\($v))"
      elif ($k == "ours.flutter_revision") then "[\($v[0:10])](https://github.com/mml555/shorebird-flutter/commit/\($v))"
      elif ($k == "ours.cli_revision") then "[\($v[0:10])](https://github.com/mml555/shorebird/commit/\($v))"
      elif ($k == "ours.engine_revision") then "[\($v[0:10])](https://github.com/flutter/flutter/commit/\($v))"
      else "`\($v)`" end;
    ($prev[0] | flat) as $p | ($cur[0] | flat) as $c
    | $c | to_entries[]
    | select($p[.key] != .value)
    | select($p | length > 0)
    | "- `\(.key)`: " + (if $p[.key] == null then "(new)" else link(.key; $p[.key]) end) + " -> " + link(.key; .value)
  '
}

report() {
  local prev=$1 state=$2
  jq -r '
    def d: if . == null or . == "" then "-" else (.[0:10]) end;
    def sha: if . == null or . == "" then "-" else .[0:10] end;
    def stack($c): "\($c.version) (Dart \($c.dart_sdk_version), \($c.release_date | d))";
    "## Upstream watch",
    "",
    "Checked \(.generated_at). Detection only; integrating an update is the manual promotion process (`selfhost/TOOLCHAIN_PROMOTION.md`).",
    "",
    "| What | Ours (supported) | Upstream |",
    "| --- | --- | --- |",
    "| Shorebird CLI | `\(.ours.cli_version)` at [`\(.ours.cli_revision | sha)`](https://github.com/mml555/shorebird/commit/\(.ours.cli_revision)) | [\(.shorebird_cli.latest_release.tag)](\(.shorebird_cli.latest_release.url)) (\(.shorebird_cli.latest_release.date | d)) |",
    "| Upstream main commits we lack | - | \(.shorebird_cli.upstream_commits_we_lack) (compare status: \(.shorebird_cli.compare_status)) |",
    "| Shorebird Flutter fork | [`\(.ours.flutter_revision | sha)`](https://github.com/mml555/shorebird-flutter/commit/\(.ours.flutter_revision)) | release branch [\(.shorebird_flutter.latest_release_branch)](https://github.com/shorebirdtech/flutter/tree/\(.shorebird_flutter.latest_release_branch)); `shorebird/dev` [\(.shorebird_flutter.dev.sha | sha)](https://github.com/shorebirdtech/flutter/commit/\(.shorebird_flutter.dev.sha)) (\(.shorebird_flutter.dev.date | d)); candidate `\(.shorebird_flutter.release_candidate_branch)` |",
    "| Engine | `\(.ours.engine_revision | sha)` | - |",
    "| Updater | `\(.ours.updater_revision)` | `main` [\(.shorebird_updater.main.sha | sha)](https://github.com/shorebirdtech/updater/commit/\(.shorebird_updater.main.sha)) (\(.shorebird_updater.main.date | d)); newest tag `\(.shorebird_updater.latest_tag)` |",
    "| Flutter stable | - | \(stack(.flutter.stable)) |",
    "| Flutter beta | - | \(stack(.flutter.beta)) |"
  ' "$state"
  echo
  echo "### New since last check"
  echo
  local list
  list=$(changes "$prev" "$state")
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
