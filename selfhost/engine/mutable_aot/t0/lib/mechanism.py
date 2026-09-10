#!/usr/bin/env python3
"""MAOT-T0 (#64) -- the patch-installation backends.

TWO BACKENDS, AND THE DISTINCTION IS A SAFETY PROPERTY.

  `none`  the real one. The Mutable-AOT mechanism does not exist yet, so it
          refuses every installation with NO_MECHANISM and every row reports
          UNMODELED. This is the backend the gate runs.

  `mock`  a test double used ONLY by the adversarial controls. It can be told
          to lie in each of the specific ways #64 requires the harness to
          catch -- report success while the slot is unchanged, update direct
          calls but leave virtual dispatch stale, keep a pre-patch tear-off
          bound to the old implementation, and so on.

A mock result can never become proof. `classify` stamps every mock-derived
row MOCK_ONLY regardless of how clean its observations look, and MOCK_ONLY is
absent from schema.RESULTS_COUNTING_AS_PROOF. Control A10 exists precisely to
show that a perfectly behaved mock still does not satisfy a row: a test double
that could prove the product is the most expensive false positive available.

The classifier is NOT duplicated per backend. Both paths hand observations to
the same `classify`, because a control that exercises a different code path
from the real run measures that other code path.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import schema as S            # noqa: E402

# Every way the mock is allowed to misbehave. Named rather than free-form so a
# control cannot invent a defect the classifier was never asked about.
MOCK_DEFECTS = (
    None,                 # behaves correctly -- still only ever MOCK_ONLY
    'slot_unchanged',     # reports success; every mode still sees the old impl
    'virtual_stale',      # direct updates, virtual dispatch does not
    'interface_stale',    # direct updates, interface dispatch does not
    'tearoff_stale',      # a tear-off taken before installation stays old
    'hot_caller_stale',   # the hot/optimized mode stays old, cold updates
    'restart',            # the process was replaced between the observations
    'wrong_value',        # something changed, but not to the expected value
    'identity_swapped',   # release and patch identities do not correspond
    'refuse',             # installation correctly refuses
)


class NoMechanism:
    """The real backend. There is nothing to install into yet."""

    name = 'none'

    def install(self, fixture, pre_observations):
        return {
            'attempted': True,
            'installed': False,
            'reported_success': False,
            'reason': 'NO_MECHANISM',
            'identity_ok': None,
            'detail': (
                'The Mutable-AOT declaration/implementation mechanism does '
                'not exist yet. #65-#70 build it. Until then every row is '
                'UNMODELED and no row can be PROVEN.'),
        }, None


class MockMechanism:
    """A test double that can lie in each named way. Never produces proof."""

    name = 'mock'

    def __init__(self, defect=None):
        if defect not in MOCK_DEFECTS:
            raise ValueError(f'undeclared mock defect {defect!r}')
        self.defect = defect

    def install(self, fixture, pre_observations):
        pre_value = fixture['expected_pre']
        post_value = fixture['expected_post']

        if self.defect == 'refuse':
            return {
                'attempted': True, 'installed': False,
                'reported_success': False, 'reason': 'REFUSED_BY_MECHANISM',
                'identity_ok': True, 'detail': 'the mock refused installation',
            }, None

        install = {
            'attempted': True, 'installed': True, 'reported_success': True,
            'reason': 'OK',
            'identity_ok': self.defect != 'identity_swapped',
            'detail': f'mock backend, defect={self.defect!r}',
        }

        post = []
        for obs in pre_observations:
            value = post_value
            nonce = obs['nonce']
            d = self.defect
            if d == 'slot_unchanged':
                value = pre_value
            elif d == 'virtual_stale' and obs['dispatch'] == 'virtual':
                value = pre_value
            elif d == 'interface_stale' and obs['dispatch'] == 'interface':
                value = pre_value
            elif d == 'tearoff_stale' and obs['dispatch'] == 'tearoff_pre':
                value = pre_value
            elif d == 'hot_caller_stale' and obs['heat_mode'] == 'hot':
                value = pre_value
            elif d == 'wrong_value':
                value = 'SOMETHING_ELSE'
            elif d == 'restart':
                # A new process would mint a new nonce. This is the shape of
                # "restart the app and call it a successful patch".
                nonce = 'restarted-' + obs['nonce']
            post.append({
                'phase': 'post',
                'dispatch': obs['dispatch'],
                'optimizer_mode': obs['optimizer_mode'],
                'heat_mode': obs['heat_mode'],
                'value': value,
                'nonce': nonce,
            })
        return install, post


def backend(name, defect=None):
    if name == 'none':
        return NoMechanism()
    if name == 'mock':
        return MockMechanism(defect)
    raise ValueError(f'unknown mechanism backend {name!r}')


def classify(fixture, pre_observations, install, post_observations,
             mechanism_name):
    """Decide a row's result. ONE implementation, shared by both backends.

    Order matters and is deliberate: infrastructure failures are decided
    BEFORE any semantic reading, because a fixture that did not behave as
    declared before the patch cannot testify about what happened after it.
    """
    reasons = []

    # 1. Did the release program behave as the fixture declares? If not, the
    #    harness is broken and every later reading is noise.
    for obs in pre_observations:
        if obs['value'] != fixture['expected_pre']:
            reasons.append('PRE_OBSERVATION_WRONG')
            return 'INFRA_FAILURE', sorted(set(reasons))

    # 2. Was every declared dispatch mode actually exercised? A fixture that
    #    silently drops a mode would let a bypass go unobserved.
    declared = set(fixture['dispatch_modes'])
    observed = {o['dispatch'] for o in pre_observations}
    if declared - observed:
        reasons.append('FIXTURE_MISSING')
        return 'INFRA_FAILURE', sorted(set(reasons))

    # 3. No mechanism yet: UNMODELED, and never anything better.
    if not install.get('installed'):
        if install.get('reason') == 'NO_MECHANISM':
            return 'UNMODELED', ['NO_MECHANISM']
        if install.get('reason') == 'REFUSED_BY_MECHANISM':
            return 'REFUSED', ['OK']
        return 'INFRA_FAILURE', ['RUN_FAILED']

    if not post_observations:
        return 'INFRA_FAILURE', ['RUN_FAILED']

    # 4. Did the process survive? A restart makes every post observation a
    #    statement about a DIFFERENT program run, so it is decided before the
    #    values are read rather than after they look convincing.
    #
    #    Compared PAIRWISE, per (optimizer, heat, dispatch), not as sets. Each
    #    mode combination is its own process, and once the mechanism exists
    #    each of those processes observes pre, installs, and observes post
    #    itself -- so the question is always "did THIS observation come from
    #    the process that produced its own pre", never "do the two piles of
    #    nonces happen to match".
    def key(o):
        return (o['optimizer_mode'], o['heat_mode'], o['dispatch'])

    pre_by_key = {key(o): o for o in pre_observations}
    for obs in post_observations:
        matching = pre_by_key.get(key(obs))
        if matching is None:
            return 'INFRA_FAILURE', ['RUN_FAILED']
        if obs['nonce'] != matching['nonce']:
            return 'RESTART_DETECTED', ['PROCESS_RESTARTED']

    # 5. Do the release and patch identities correspond?
    if install.get('identity_ok') is False:
        return 'WRONG_SEMANTICS', ['IDENTITY_MISMATCH']

    # 6. Read the values, per mode.
    stale, wrong = [], []
    for obs in post_observations:
        if obs['value'] == fixture['expected_post']:
            continue
        if obs['value'] == fixture['expected_pre']:
            stale.append(obs)
        else:
            wrong.append(obs)

    if wrong:
        reasons.append('WRONG_VALUE')
        if stale:
            reasons.append('DISPATCH_MODE_STALE')
        return 'WRONG_SEMANTICS', sorted(set(reasons))

    if stale:
        # Everything stale with a success report is a fail-open. Some modes
        # stale is a BYPASS: the mechanism moved, and one path did not follow.
        if len(stale) == len(post_observations):
            return 'FAIL_OPEN', ['SLOT_UNCHANGED']
        for obs in stale:
            if obs['dispatch'] == 'tearoff_pre':
                reasons.append('TEAROFF_STALE')
            elif obs['heat_mode'] == 'hot':
                reasons.append('HOT_CALLER_STALE')
            else:
                reasons.append('DISPATCH_MODE_STALE')
        return 'WRONG_SEMANTICS', sorted(set(reasons))

    # 7. Everything observed the new implementation. Only the real backend may
    #    turn that into proof.
    if mechanism_name != 'none':
        return 'MOCK_ONLY', ['MOCK_BACKEND']
    return 'PROVEN', ['OK']
