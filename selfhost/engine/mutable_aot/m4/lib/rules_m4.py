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
    'unmodeled optimizer classes': {
        'rule': 'CHA, polymorphic-call specialization, dispatch-table '
                'specialization, tear-off target caching, recognized/'
                'intrinsic replacement and accessor subsumption are not '
                'modeled by #68',
        'enforcement': 'they can only reach a mutable declaration through an '
                       'instance member or a tear-off; instance members are '
                       'blocked above, and a tear-off of a mutable member is '
                       'an instance member too',
        'disposition': 'UNMODELED_BLOCKING',
        'producer': 'the instance-dispatch rule subsumes them',
        'consumer': 'MaotRegistry::StageReplacement refuses installation',
        'falsification': 'H08 -- the same arm, because the same blocker '
                         'covers them. Stated rather than claimed as '
                         'separately proven',
    },
}

REQUIRED_FIELDS = ('rule', 'enforcement', 'disposition', 'producer',
                   'consumer', 'falsification')
