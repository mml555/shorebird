#!/usr/bin/env python3
"""Field-by-field parity between the reference tooling, the shipped analyzer,
and the CLI's parser.

Every comparison here is exact. A near-match is a mismatch: the point of the
harness is that a transcription slip is otherwise indistinguishable from a
genuine "unsupported target" result, and both look like a refused patch.

The reference tools report REJECTION COUNTS, not per-target reasons, so the
per-target reasons are reconstructed from the reference manifest -- which is
where the reference gets them from too. That reconstruction is the point of
comparison for "same rejection reason for each".
"""
import argparse
import json
import sys


def load(path):
    with open(path) as f:
        return json.load(f)


class Report:
    def __init__(self, case):
        self.case = case
        self.problems = []

    def check(self, label, left_name, left, right_name, right):
        if left != right:
            self.problems.append(
                f"{label}\n"
                f"        {left_name:<10} {left!r}\n"
                f"        {right_name:<10} {right!r}"
            )

    def finish(self):
        if not self.problems:
            print(f"  PASS  {self.case}")
            return 0
        print(f"  FAIL  {self.case}")
        for p in self.problems:
            print(f"        {p}")
        return 1


def reference_rejections(ref_changed, ref_targets):
    """Rebuild per-target rejections the way build_patch.dart's rules imply.

    Same three rules, same manifest reasons. If the analyzer disagrees with
    this, one of the two changed a rule while moving it.
    """
    reason_for = {
        f"{t['library']}#{t['selector']}": t["reason"]
        for t in ref_targets["targets"]
    }
    out = []
    for key in ref_changed["unreachable"]:
        out.append(
            {"target": key, "category": "unreachable", "reason": reason_for[key]}
        )
    for key in ref_changed["unknown"]:
        out.append(
            {
                "target": key,
                "category": "unknown",
                "reason": "not in the release manifest; unknown reachability "
                "is not the same as reachable",
            }
        )
    for key in ref_changed["added"]:
        out.append(
            {
                "target": key,
                "category": "added",
                "reason": "a patch replaces bodies and cannot introduce "
                "members, so bytecode referencing them would fail to bind",
            }
        )
    return out


def reference_verdict(ref_changed, ref_rc):
    """build_patch.dart's exit codes, as a verdict.

    0 = shippable, 3 = nothing changed, 4 = refused.
    """
    if ref_rc == 3:
        return "inert"
    if ref_rc == 4:
        return "reject"
    if ref_rc == 0:
        return "accept"
    raise SystemExit(f"reference tool exited {ref_rc}, which is not a verdict")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case", required=True)
    ap.add_argument("--ref-changed", required=True)
    ap.add_argument("--ref-targets", required=True)
    ap.add_argument("--ref-rc", required=True, type=int)
    ap.add_argument("--analysis", required=True)
    ap.add_argument("--cli", required=True)
    ap.add_argument("--expected")
    args = ap.parse_args()

    ref_changed = load(args.ref_changed)
    ref_targets = load(args.ref_targets)
    analysis = load(args.analysis)
    cli = load(args.cli)

    r = Report(args.case)

    # --- target identity ---------------------------------------------------
    # The whole manifest, not a count. `selector` carries the get:/set:
    # mangling and the class qualification, and a getter read as an unpatchable
    # form once because those were composed by hand at a call site.
    r.check(
        "target identity (manifest)",
        "reference",
        ref_targets["targets"],
        "analyzer",
        analysis["targets"],
    )

    # --- changed / added / removed ----------------------------------------
    for field in ("changed", "added", "removed"):
        r.check(
            f"{field} set",
            "reference",
            sorted(ref_changed[field]),
            "analyzer",
            sorted(analysis[field]),
        )
        r.check(
            f"{field} set",
            "analyzer",
            sorted(analysis[field]),
            "cli",
            sorted(cli[field]),
        )

    # --- representability --------------------------------------------------
    r.check(
        "representable set",
        "reference",
        sorted(ref_changed["patchable"]),
        "analyzer",
        sorted(analysis["patchable"]),
    )
    r.check(
        "representable set",
        "analyzer",
        sorted(analysis["patchable"]),
        "cli",
        sorted(cli["representable"]),
    )
    # `conditional` is a third state, never folded into either side. Folding it
    # into representable would ship instance-member patches as proven; folding
    # it into rejected would refuse every one of them.
    r.check(
        "conditional set",
        "reference",
        sorted(ref_changed["conditional"]),
        "analyzer",
        sorted(analysis["conditional"]),
    )
    r.check(
        "conditional set",
        "analyzer",
        sorted(analysis["conditional"]),
        "cli",
        sorted(cli["conditional"]),
    )
    r.check(
        "unreachable set",
        "reference",
        sorted(ref_changed["unreachable"]),
        "analyzer",
        sorted(analysis["unreachable"]),
    )
    r.check(
        "unknown set",
        "reference",
        sorted(ref_changed["unknown"]),
        "analyzer",
        sorted(analysis["unknown"]),
    )

    # --- exact rejection reason, per target --------------------------------
    key = lambda xs: sorted(xs, key=lambda d: (d["category"], d["target"]))
    r.check(
        "rejections (target + category + exact reason)",
        "reference",
        key(reference_rejections(ref_changed, ref_targets)),
        "analyzer",
        key(analysis["rejections"]),
    )
    r.check(
        "rejections (target + category + exact reason)",
        "analyzer",
        key(analysis["rejections"]),
        "cli",
        key(cli["rejections"]),
    )

    # --- whole-patch verdict -----------------------------------------------
    r.check(
        "whole-patch verdict",
        "reference",
        reference_verdict(ref_changed, args.ref_rc),
        "analyzer",
        analysis["verdict"],
    )
    r.check(
        "whole-patch verdict",
        "analyzer",
        analysis["verdict"],
        "cli",
        cli["verdict"],
    )

    # --- the case's own pinned expectation ---------------------------------
    # Parity alone would stay green if all three drifted the same way -- which
    # is exactly what happens when the reference itself is edited. The pin is
    # what makes "the dispatch-table case is not detected" a recorded fact
    # rather than a silence.
    if args.expected:
        expected = load(args.expected)
        for field, actual in (
            ("verdict", analysis["verdict"]),
            ("changed", sorted(analysis["changed"])),
            ("patchable", sorted(analysis["patchable"])),
            ("conditional", sorted(analysis["conditional"])),
            ("unreachable", sorted(analysis["unreachable"])),
            ("added", sorted(analysis["added"])),
        ):
            if field in expected:
                r.check(f"pinned {field}", "expected", expected[field],
                        "analyzer", actual)
        if "rejectionReasons" in expected:
            r.check(
                "pinned rejection reasons",
                "expected",
                expected["rejectionReasons"],
                "analyzer",
                sorted(x["reason"] for x in analysis["rejections"]),
            )

    return r.finish()


if __name__ == "__main__":
    sys.exit(main())
