# Patches to the pinned Flutter SDK

> **Retained as provenance, not as an installation step.** The supported
> revision — `flutter_revision` in `selfhost/compatibility.yaml`, currently
> `a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61` on `refs/heads/selfhost/3.44.8` —
> **already contains** 0001. Do **not** apply it to the supported toolchain: it
> will fail, or worse, apply twice. The file is kept so the change is reviewable
> as a diff and so its reason survives independently of the commit message.

Unlike `selfhost/engine/*.patch`, which patch the **engine** tree, these patch
the **Flutter framework/tools** checkout that `selfhost/compatibility.yaml` pins
via `flutter_revision`.

They are **local modifications to a pinned toolchain**, which is exactly the
hazard `coherent-set-not-single-file` warns about: a fresh bootstrap from
`selfhost/cdn/mirrors/flutter.git` will NOT have them. Each one below therefore
names what breaks without it, so a lost patch is diagnosable rather than
mysterious.

## 0001-shorebird-yaml-carry-channel.patch

`flutter_tools`' `compileShorebirdYaml`
(`packages/flutter_tools/lib/src/shorebird/shorebird_yaml.dart`) rebuilds the
bundled `shorebird.yaml` from scratch during a build: it starts from the
flavor-resolved `app_id` and then copies only `base_url`, `auto_update` and
`patch_verification`. `channel` was not copied, so it never reached the device.

**Without this patch:** `channel: beta` in the project's `shorebird.yaml` is
accepted by the CLI and silently absent from the shipped bundle, so the automatic
updater keeps requesting `stable`. The symptom is a client that looks correctly
configured and is not.

**Why it matters that the seam spans two repos.** Supporting `channel:` needed
changes in *both* `shorebird_cli` (the model and its generated parser, this repo)
and `flutter_tools` (this patch, the Flutter fork). Fixing only the first makes
the key parseable but inert — which is worse than rejecting it, because rejection
at least told the user. Discovered by checking the **shipped artifact** rather
than trusting the release to have carried the source through.

To apply against a fresh checkout:

```sh
git -C "$FLUTTER_ROOT" apply selfhost/flutter/0001-shorebird-yaml-carry-channel.patch
rm -f "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot" \
      "$FLUTTER_ROOT/bin/cache/flutter_tools.stamp"
```

**The second command is not optional.** `flutter_tools` runs from a cached
snapshot keyed on the SDK revision, not on source content, so editing the source
alone changes nothing: the patch was applied, a release was cut, and the shipped
bundle still lacked `channel` — a full release burned proving that source edits
to `flutter_tools` are inert until the snapshot is invalidated.

**Proper home:** upstream into the fork's Flutter mirror so the pinned revision
carries it, at which point this file becomes a record rather than a step.
