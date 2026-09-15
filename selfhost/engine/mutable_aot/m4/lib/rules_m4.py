#!/usr/bin/env python3
"""MAOT-4 (#68) -- the per-pass optimizer rule table.

Every optimizer class #68 names, with:

  enforcement   where the rule is actually applied, by file
  disposition   FORBIDDEN / SLOT_PRESERVING / DEPENDENCY_REQUIRED /
                UNMODELED_BLOCKING
  producer      what emits the evidence
  consumer      the real decision that reads it -- or an explicit statement
                that nothing does, which is only allowed for SLOT_PRESERVING
  falsification the live arm that demonstrates the rule is load-bearing

A rule without a falsification is a claim. A rule whose consumer is a log line
is decoration. The gate checks both, in both directions.
"""

# Dispositions that must block installation. Mirrors
# MaotRegistry::BlocksInstallation; the gate asserts the two agree by
# measurement rather than by reading this list.
BLOCKING = ('FORBIDDEN', 'UNMODELED_BLOCKING', 'DEPENDENCY_REQUIRED')

RULES = {
    'inlining': {
        'rule': 'a selected declaration is never inlined, because an inlined '
                'copy is a caller that cannot reach the dispatch cell',
        'enforcement': 'precompiler.cc SeedMutableAotRoots sets '
                       'is_inlinable(false); inliner.cc ShouldWeInline '
                       'refuses before AlwaysInline, so a force-inline pragma '
                       'cannot win',
        'disposition': 'FORBIDDEN',
        'producer': 'the refusal is structural -- no inlined copy exists to '
                    'record',
        'consumer': 'none needed: the optimization does not happen. The '
                    'OBSERVABLE consequence is that a vm:prefer-inline '
                    'mutable callee still observes its replacement',
        'falsification': 'H10',
    },
    'constant-folding': {
        'rule': 'no constant result may be attached to a call whose target is '
                'mutable; the caller would use the release answer while the '
                'call still reaches the cell',
        'enforcement': 'transformer.dart suppresses the constant; '
                       'kernel_binary_flowgraph.cc BuildStaticInvocation '
                       'records FORBIDDEN if one arrives anyway',
        'disposition': 'FORBIDDEN',
        'producer': 'MaotRegistry::NoteDecision at the VM backstop',
        'consumer': 'MaotRegistry::StageReplacement refuses installation',
        'falsification': 'H04',
    },
    'static-call-lowering': {
        'rule': 'a direct or static call to a mutable target must load the '
                'dispatch cell',
        'enforcement': 'flow_graph_compiler_arm64.cc GenerateStaticDartCall',
        'disposition': 'SLOT_PRESERVING',
        'producer': 'NoteDecision + NoteCallSiteEmitted per site',
        'consumer': 'nothing reads a slot-preserving record; it is positive '
                    'evidence. The ABSENCE of the lowering is what is '
                    'consumed -- it records FORBIDDEN and refuses install',
        'falsification': 'H01',
    },
    'devirtualization': {
        'rule': 'the optimizer may turn an instance call into a static call; '
                'the resulting edge must still traverse the cell',
        'enforcement': 'kernel_binary_flowgraph.cc, every '
                       'DirectCallMetadata-to-StaticCall site including '
                       'BuildMethodInvocation and the dynamic forwarders',
        'disposition': 'SLOT_PRESERVING',
        'producer': 'NoteDecision naming the function TFA proved, not the '
                    'forwarder that gets called',
        'consumer': 'nothing reads it directly; the gate joins it with the '
                    'static-call-lowering record for the same target and '
                    'caller, and a devirtualization without that partner '
                    'would leave the target with zero emitted call sites',
        'falsification': 'H09',
    },
    'instance-dispatch': {
        'rule': 'a selected INSTANCE member is reachable by dispatch forms '
                '#68 does not model',
        'enforcement': 'precompiler.cc SeedMutableAotRoots',
        'disposition': 'UNMODELED_BLOCKING',
        'producer': 'NoteDecision at seeding',
        'consumer': 'MaotRegistry::StageReplacement refuses installation',
        'falsification': 'H08',
    },
    'target-architecture': {
        'rule': 'a target with no Mutable-AOT call lowering cannot host a '
                'replaceable declaration',
        'enforcement': 'precompiler.cc, guarded on TARGET_ARCH_ARM64',
        'disposition': 'FORBIDDEN',
        'producer': 'NoteEscapeById at seeding',
        'consumer': 'MaotRegistry::StageReplacement refuses installation',
        'falsification': 'covered structurally: the arm64 build records no '
                         'such escape, and the guard is the #else branch of '
                         'the only lowering that exists. H13 covers the '
                         'related "binaries not built from these sources" '
                         'case',
    },
    'tfa-retention': {
        'rule': 'a selected declaration the release never calls must survive '
                'tree shaking and stay addressable',
        'enforcement': 'pragma.dart makes maot:mutable an entry point; '
                       'precompiler.cc AddFunction with '
                       'kMutableAotDeclaration',
        'disposition': 'SLOT_PRESERVING',
        'producer': 'the registry entry itself, with '
                    'indirect_call_sites_emitted = 0',
        'consumer': 'nothing blocks; the observable consequence is that the '
                    'declaration is installable and its version advances',
        'falsification': 'H12',
    },
    'dependency-carrying optimizations': {
        'rule': 'an optimization that crosses the boundary is allowed only '
                'with invalidation state the install path can act on',
        'enforcement': 'MaotRegistry::BlocksInstallation',
        'disposition': 'DEPENDENCY_REQUIRED',
        'producer': 'nothing produces one yet -- Phase B owns the token',
        'consumer': 'none exists, which is precisely why it fails closed. '
                    'Admitting it today would be admitting an optimization '
                    'on a promise',
        'falsification': 'H05',
    },
    'recognized-or-intrinsic': {
        'rule': 'a recognized or intrinsified declaration may not be mutable, '
                'because the compiler can replace its body with inline code '
                'at the call site and no dispatch cell mediates that',
        'enforcement': 'precompiler.cc, Function::IsRecognized() or '
                       'is_intrinsic() at seeding',
        'disposition': 'FORBIDDEN',
        'producer': 'NoteDecision at seeding',
        'consumer': 'MaotRegistry::StageReplacement refuses installation',
        'falsification': 'H16',
        'why_not_covered_by_instance_dispatch':
            'an earlier version of this table claimed the instance-dispatch '
            'blocker covered it. That was wrong: dart:core\'s identical and a '
            'number of top-level Developer and FFI functions are recognized '
            'and STATIC. SDK declarations separately cannot be selected -- '
            'collectSelected and index skip dart: libraries -- and the gate '
            'asserts the selected set contains no dart: id; but a USER '
            'declaration can carry vm:recognized, which is the case this rule '
            'closes.',
    },
    'accessor-subsumption': {
        'rule': 'a field or accessor transformation that would subsume a '
                'mutable accessor body is refused',
        'enforcement': 'implicit getters and setters are instance members and '
                       'are blocked by instance-dispatch; a static or '
                       'top-level accessor is an ordinary static call and is '
                       'lowered through the cell like any other',
        'disposition': 'UNMODELED_BLOCKING',
        'producer': 'the instance-dispatch rule for the instance case; the '
                    'static-call-lowering rule for the static case',
        'consumer': 'MaotRegistry::StageReplacement refuses the instance '
                    'case; the static case is slot-preserving and installs',
        'falsification': 'H08 for the instance half. The static half is '
                         'covered by H01, since a static accessor is a static '
                         'call. Stated rather than claimed as separately '
                         'proven.',
    },
}

REQUIRED_FIELDS = ('rule', 'enforcement', 'disposition', 'producer',
                   'consumer', 'falsification')

# The optimizer classes #68 names, transcribed from the issue's own
# "At minimum inspect/control" list. This set is INDEPENDENT of RULES on
# purpose: checking that every key in RULES has populated fields says nothing
# about a class that was dropped from RULES entirely, and the first version of
# this gate could not tell the difference. H15 removes a class and requires
# the condition to fail.
REQUIRED_CLASSES = {
    'inlining',
    'constant-folding',            # "constant propagation/folding through
                                   #  mutable calls"
    'tfa-retention',               # "TFA body/result materialization" and
                                   #  "any precompiler transformation that
                                   #   removes the mutable declaration"
    'static-call-lowering',        # "direct-call target binding"
    'devirtualization',            # "CHA/devirtualization"
    'instance-dispatch',           # "polymorphic-call specialization",
                                   #  "dispatch-table specialization",
                                   #  "tear-off target caching"
    'recognized-or-intrinsic',     # "recognized/intrinsic replacement where
                                   #  it would erase mutability"
    'accessor-subsumption',        # "field/accessor transformations that
                                   #  subsume a mutable accessor body"
    'target-architecture',
    'dependency-carrying optimizations',
}


# ---------------------------------------------------------------------------
# The recognized/intrinsic population, proven from the VM's own tables.
#
# Function::IsRecognized() is recognized_kind() != kUnknown, and
# recognized_kind is assigned in exactly one place:
# MethodRecognizer::InitializeState(), which expands RECOGNIZED_LIST,
# ASM_INTRINSICS_LIST and GRAPH_INTRINSICS_LIST and resolves each row with
#
#     lib = Library::<first column>();
#     func = Library::GetFunction(lib, class, name);
#
# @pragma('vm:recognized') does NOT assign it -- object.cc only CHECKS that a
# function already in the table carries a matching pragma. So the recognized
# population is exactly what those tables name, and if every row names an SDK
# library then no user declaration can ever be recognized or intrinsic.
#
# That "if" is the whole proof, and it is checkable: these are the library
# accessors the VM considers SDK. A row naming anything else fails the check
# rather than quietly widening the population.
SDK_LIBRARY_ACCESSORS = frozenset({
    'AsyncLibrary', 'CollectionLibrary', 'CompactHashLibrary',
    'ConcurrentLibrary', 'ConvertLibrary', 'CoreLibrary', 'DeveloperLibrary',
    'FfiLibrary', 'InternalLibrary', 'IsolateLibrary', 'MathLibrary',
    'MirrorsLibrary', 'NativeWrappersLibrary', 'TypedDataLibrary',
    'VMServiceLibrary', 'VMLibrary',
})

# The macro blocks InitializeState() actually expands. A block that assigns
# recognized_kind and is not listed here would be missed, so the check also
# asserts every one of these is present in the header.
RECOGNIZED_TABLE_BLOCKS = (
    'OTHER_RECOGNIZED_LIST',
    'ASM_INTRINSICS_LIST',
    'GRAPH_INTRINSICS_LIST',
)


def recognized_table_libraries(header_text):
    """Library-column values of every row in the recognized/intrinsic tables.

    Returns (libraries, blocks_found). A row is `V(Library, Class, name, Enum,
    fingerprint)`; rows with fewer columns belong to a different macro and are
    not part of this population.
    """
    libs, blocks = set(), []
    lines = header_text.splitlines()
    current = None
    for line in lines:
        st = line.strip()
        if st.startswith('#define ') and st.split('(')[0][8:].endswith('_LIST'):
            current = st.split('(')[0][8:]
            if current in RECOGNIZED_TABLE_BLOCKS:
                blocks.append(current)
            continue
        if current not in RECOGNIZED_TABLE_BLOCKS:
            continue
        if not st.startswith('V('):
            continue
        parts = [p.strip() for p in st[2:].rstrip('\\').strip().rstrip(')')
                 .split(',')]
        if len(parts) >= 5:
            libs.add(parts[0])
    return libs, blocks
