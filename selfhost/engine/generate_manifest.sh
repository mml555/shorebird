#!/usr/bin/env bash
# generate_manifest.sh — write artifacts_manifest.yaml for one of OUR engine
# hashes, from explicit inputs rather than from whatever script a build host
# happened to have lying around.
#
#   selfhost/engine/generate_manifest.sh \
#     --hash 70974f81... --base-manifest <path-or-url> \
#     --flutter-revision c15ef637... --dart-revision 6b58bb3a... \
#     --host darwin-arm64 --target ios [--out <file>]
#
# WHY THIS EXISTS
#
# The two supported cells were carrying manifests written by two DIFFERENT
# upstream scripts that disagreed about the central field:
#
#   70974f81  shard_runner:finalize template     flutter_engine_revision: 83675ed2  (correct)
#   760e3fab  artifact_proxy/tool/generate_...   flutter_engine_revision: 760e3fab  (its own hash)
#
# `flutter_engine_revision` is documented in
# artifact_proxy/lib/src/models/artifacts_manifest.dart:50 as "the flutter
# engine revision that this engine mapping is based on" — the UPSTREAM Flutter
# engine. It is the revision the proxy resolves any NON-overridden artifact
# from, on Flutter's CDN. Naming our own hash there points those lookups at a
# revision Flutter has never published.
#
# It is inert today only because Caddy rewrites an experimental hash to the
# pinned one before artifact_proxy sees it. That is load-bearing and is written
# down nowhere in the manifests, which is precisely how the drift survived.
#
# WHAT THIS DOES NOT DO
#
# It does not invent an artifact_overrides list. That list means "fetch from
# storage_bucket under $engine instead of from Flutter's CDN", and our engine
# lives in exactly the same path space as a stock Shorebird engine, so it needs
# the SAME overrides. Shortening it to "only what we built" would be a
# behavior change dressed up as a cleanup: artifacts.zip and friends exist only
# in the Shorebird bucket, override list or not.
#
# Which artifacts we actually PRODUCED is a different question, answered by
# provenance.yaml (cdn/audit_overlay.sh --emit-manifest) from
# cdn/artifact_policy.conf. Keep the two files separate:
#
#   artifacts_manifest.yaml  compatibility artifact consumed by the tooling
#   provenance.yaml          our audit record of where each byte came from
set -euo pipefail

# Needed by the "base revision is one of ours" guard below. Overridable so the
# guard can be exercised against a scratch overlay.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
OVERLAY="${OVERLAY:-$HERE/../cdn/overlay}"

HASH=""; BASE=""; FLUTTER_REV=""; DART_REV=""; HOST=""; TARGET=""; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hash) HASH="${2:?}"; shift 2 ;;
    --base-manifest) BASE="${2:?}"; shift 2 ;;
    --flutter-revision) FLUTTER_REV="${2:?}"; shift 2 ;;
    --dart-revision) DART_REV="${2:?}"; shift 2 ;;
    --host) HOST="${2:?}"; shift 2 ;;
    --target) TARGET="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for v in HASH BASE FLUTTER_REV DART_REV HOST TARGET; do
  eval "[[ -n \"\${$v}\" ]]" || { echo "ERROR: --${v//_/-} is required (see --help)" >&2; exit 2; }
done

# --- The base manifest, which supplies the override list and the TRUE base ---
# Accept a local path or a URL, so this works from the overlay or through the
# mirror on a host that has no copy.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
case "$BASE" in
  http://*|https://*)
    curl -fsSL "$BASE" -o "$TMP/base.yaml" \
      || { echo "ERROR: could not fetch base manifest: $BASE" >&2; exit 2; } ;;
  *)
    [[ -r "$BASE" ]] || { echo "ERROR: cannot read base manifest: $BASE" >&2; exit 2; }
    cp "$BASE" "$TMP/base.yaml" ;;
esac

BASE_REV="$(awk '/^flutter_engine_revision:/ {print $2; exit}' "$TMP/base.yaml")"
BUCKET="$(awk '/^storage_bucket:/ {print $2; exit}' "$TMP/base.yaml")"
[[ -n "$BASE_REV" && -n "$BUCKET" ]] || {
  echo "ERROR: base manifest has no flutter_engine_revision / storage_bucket." >&2
  echo "       Is $BASE really an artifacts_manifest.yaml?" >&2; exit 2; }

# Refuse the exact mistake this script exists to stop: a base manifest that
# names a custom hash as the upstream Flutter engine. Using it would launder
# the bug into the new file.
if [[ "$BASE_REV" == "$HASH" ]]; then
  echo "ERROR: the base manifest's flutter_engine_revision is $BASE_REV, which is" >&2
  echo "       the very hash you are generating for. That field must name the" >&2
  echo "       UPSTREAM FLUTTER engine this build is based on. Pass a base" >&2
  echo "       manifest from the pinned Shorebird revision instead." >&2
  exit 2
fi

# The check above was too narrow, and that is not hypothetical: on 2026-08-14 a
# manifest was generated for 40eaa0ef from 881e4129's manifest. 881e4129 is one
# of OUR hashes carrying the self-naming drift this script exists to fix, but it
# is not the hash being generated, so the equality test passed and the bug was
# laundered into two new files. The audit went GREEN on it, because the audit
# checks that the file exists, not what it claims.
#
# So refuse ANY base whose revision is one of our own published engine hashes,
# not merely this one. An upstream Flutter revision is never a directory here.
if [[ -d "$OVERLAY/flutter_infra_release/flutter/$BASE_REV" ]]; then
  echo "ERROR: the base manifest's flutter_engine_revision is $BASE_REV, which is" >&2
  echo "       one of OUR published engine hashes — it is a directory under" >&2
  echo "       $OVERLAY/flutter_infra_release/flutter/." >&2
  echo "       That field must name the UPSTREAM FLUTTER engine, which the proxy" >&2
  echo "       resolves every NON-overridden artifact from on Flutter's CDN;" >&2
  echo "       naming one of ours points those lookups at a revision Flutter has" >&2
  echo "       never published." >&2
  echo "       Pass a base manifest that carries an upstream revision — e.g." >&2
  echo "       70974f81…'s, which names 83675ed2…, as does the pinned 69f9831c…." >&2
  exit 2
fi

OUT="${OUT:-$TMP/artifacts_manifest.yaml}"
{
  echo "# GENERATED by selfhost/engine/generate_manifest.sh — do not hand-edit."
  echo "#"
  echo "# This describes one of OUR engine hashes. Provenance of the individual"
  echo "# artifacts is NOT here — see provenance.yaml, written by"
  echo "# selfhost/cdn/audit_overlay.sh --emit-manifest from artifact_policy.conf."
  echo "#"
  echo "# selfhost_engine_hash:  $HASH"
  echo "# flutter_revision:      $FLUTTER_REV"
  echo "# dart_sdk_revision:     $DART_REV"
  echo "# built_on_host:         $HOST"
  echo "# target:                $TARGET"
  echo "# override_list_from:    $BASE (base revision $BASE_REV)"
  echo "#"
  echo "# flutter_engine_revision below is the UPSTREAM FLUTTER engine this is"
  echo "# based on — NOT $HASH. The proxy resolves every non-overridden artifact"
  echo "# from Flutter's CDN under it, and Flutter has never published our hash."
  echo "flutter_engine_revision: $BASE_REV"
  echo "storage_bucket: $BUCKET"
  # The override list is copied verbatim: our engine occupies the same path
  # space as a stock Shorebird engine and needs the same overrides.
  awk '/^artifact_overrides:/{p=1} p' "$TMP/base.yaml"
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

echo "wrote $OUT"
echo "  flutter_engine_revision: $BASE_REV  (upstream Flutter base)"
echo "  storage_bucket:          $BUCKET"
echo "  overrides:               $(grep -c '^  - ' "$OUT") entries"
