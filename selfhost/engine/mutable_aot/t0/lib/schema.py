#!/usr/bin/env python3
"""MAOT-T0 (#64) -- the evidence schema and result vocabulary. ONE definition.

Imported by the corpus builder, the runner, the adversarial controls and the
aggregate, so a result enum cannot mean one thing to the producer and another
to the gate.

The row set is NOT defined here. It is read from maot0/matrix.json (#63).
Keeping a second list is the specific failure #64's first acceptance box
forbids, and the corpus check fails in both directions: a matrix row with no
fixture, and a fixture with no matrix row.
"""

EVIDENCE_SCHEMA = 'maot.t0.evidence/1'
ROW_SCHEMA = 'maot.t0.row/1'
FIXTURE_SCHEMA = 'maot.t0.fixture/1'

# ------------------------------------------------------------------ results

# #64's enum, plus the three states its own adversarial controls require be
# distinguishable. A single "failed" bucket would make "the harness caught a
# bypass" indistinguishable from "the compiler was missing".
RESULTS = (
    'PROVEN',           # observed the new implementation on every mode
    'REFUSED',          # installation correctly refused; the row expected it
    'UNMODELED',        # no mechanism exists for this row yet
    'INFRA_FAILURE',    # the harness or the fixture is broken; NOT a verdict
    'FAIL_OPEN',        # installation reported success while nothing changed
    'WRONG_SEMANTICS',  # something changed, but not to what was expected
    'RESTART_DETECTED',  # the process died; any "pass" here is an artifact
    'MOCK_ONLY',        # produced by the mock backend; never counts as proof
)

# A row result that may contribute to a universal-support claim. Deliberately
# a whitelist: a new result enum added later is excluded until someone decides
# it should count, rather than silently joining the passing set.
RESULTS_COUNTING_AS_PROOF = ('PROVEN',)

# Results that indicate the HARNESS failed rather than the mechanism. These
# never satisfy a row and never quietly become UNMODELED either -- an
# infrastructure failure that degrades to "not modeled yet" is how a broken
# harness stops being noticed.
RESULTS_INFRA = ('INFRA_FAILURE', 'RESTART_DETECTED')

REASONS = (
    'NO_MECHANISM',            # the Mutable-AOT mechanism does not exist yet
    'OK',
    'SLOT_UNCHANGED',          # installer said success; the slot did not move
    'DISPATCH_MODE_STALE',     # one dispatch form still reaches the old impl
    'TEAROFF_STALE',           # a pre-patch tear-off still reaches the old impl
    'HOT_CALLER_STALE',        # an optimized/hot caller still reaches the old
    'PROCESS_RESTARTED',       # process identity changed across the transition
    'IDENTITY_MISMATCH',       # release/patch identities do not correspond
    'PRE_OBSERVATION_WRONG',   # the release program did not behave as declared
    'COMPILE_FAILED',
    'RUN_FAILED',
    'STALE_EVIDENCE',          # a prior run's record survived a failed run
    'FIXTURE_MISSING',
    'MOCK_BACKEND',            # result came from the test double
    'WRONG_VALUE',             # changed to something nobody asked for
)

# ------------------------------------------------------------------- modes

# #64 lists "minimum fixture families" that are finer-grained than #63's rows:
# virtual call, interface call, super call, tear-off before/after the patch.
# They are modelled here as MODES OF ONE ROW rather than as separate rows, and
# that is a deliberate reconciliation rather than an omission.
#
# The reason is #62's I2. If `direct` and `virtual` were separate rows, an
# implementation that updated direct calls and left virtual dispatch stale
# would report 50% -- a number. As modes of one row it reports what it is: a
# BYPASS, and the row does not pass. A row's dispatch_correctness axis is
# satisfied only when every applicable dispatch mode observes the new
# implementation.
DISPATCH_MODES = (
    'direct',        # statically bound call
    'virtual',       # through a subclass-typed receiver
    'interface',     # through an interface-typed receiver
    'super',         # super.m() from a subclass
    'dynamic',       # dynamic receiver, megamorphic-capable
    'tearoff_pre',   # tear-off captured BEFORE installation
    'tearoff_post',  # tear-off captured after installation
)

OPTIMIZER_MODES = (
    'jit',   # unoptimized/interpreted-ish; the control
    'aot',   # AOT snapshot: inlining, TFA, devirtualization all on
)

HEAT_MODES = (
    'cold',  # first invocation
    'hot',   # after a large invocation count, so caches are warm/specialized
)

HEAT_ITERATIONS = {'cold': 1, 'hot': 20000}


def blank_row_result(row_id, gate_id):
    """The shape every row record must fill. Absent fields are not defaults.

    Every field starts at None or an explicit unknown so a producer that
    forgets one yields a record the validator rejects, rather than a record
    that reads as a pass.
    """
    return {
        'schema': ROW_SCHEMA,
        'row_id': row_id,
        'gate_id': gate_id,
        'executable': None,
        'result': None,
        'reasons': [],
        'mechanism': None,
        'release_source_sha256': None,
        'patch_source_sha256': None,
        'toolchain': None,
        'release_artifact': None,
        'patch_artifact': None,
        'pre_observation': None,
        'install_result': None,
        'post_observation': None,
        'process_restarted': None,
        'old_state_existed': None,
        'expected_pre': None,
        'expected_post': None,
        'mode_results': [],
        'path_evidence': None,
        'generated_at': None,
        'generator': None,
    }
