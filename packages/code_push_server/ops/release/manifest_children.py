#!/usr/bin/env python3
"""Print `<digest> <os>/<arch>` for each real platform manifest in an index.

Attestation manifests carry platform.os == "unknown" and are skipped: they are
not architectures a client can run, and counting them would make the
architecture binding in publish_release.sh report entries no release claims.
"""
import json
import sys

doc = json.load(sys.stdin)
for m in doc.get("manifests", []):
    plat = m.get("platform") or {}
    if plat.get("os") == "unknown":
        continue
    print(m["digest"], "{}/{}".format(plat.get("os", "?"), plat.get("architecture", "?")))
