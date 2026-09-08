#!/usr/bin/env bash
# Re-derive the recorder-completeness enumeration from a Dart source tree.
#
# evidence/recorder_completeness.md asserts a set of counts and gates. This
# script derives them again and fails if the tree disagrees, so the document
# cannot drift away from the source it cites.
#
# usage: verify_completeness.sh <dart-tree-root>   # the dir containing runtime/
set -uo pipefail
T="${1:?usage: verify_completeness.sh <dart-tree-root>}"/runtime
[ -d "$T/vm" ] || { echo "no $T/vm"; exit 2; }
fail=0
ck() { # ck <description> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  pass  %-58s %s\n' "$1" "$3"
  else printf '  FAIL  %-58s got %s, expected %s\n' "$1" "$3" "$2"; fail=1; fi
}
g() { grep -rn --include='*.cc' --include='*.h' "$@" "$T/vm" 2>/dev/null; }

echo "recorder completeness, re-derived from $T"

# Claim A: FlowGraphCompiler construction sites.
ck 'FlowGraphCompiler construction sites' 3 \
   "$(g 'FlowGraphCompiler graph_compiler\|new FlowGraphCompiler' | wc -l | tr -d ' ')"
ck 'of which in aot/precompiler.cc' 1 \
   "$(g 'FlowGraphCompiler graph_compiler\|new FlowGraphCompiler' | grep -c 'aot/precompiler.cc')"
ck 'of which in jit/compiler.cc' 1 \
   "$(g 'FlowGraphCompiler graph_compiler\|new FlowGraphCompiler' | grep -c 'jit/compiler.cc')"
ck 'of which in test helpers' 1 \
   "$(g 'FlowGraphCompiler graph_compiler\|new FlowGraphCompiler' | grep -c 'il_test_helper.cc')"

# Claim B: writers of the registry, and callers of the one registration point.
ck 'appends to inline_id_to_function' 3 \
   "$(g 'inline_id_to_function[_]*\(\?\)*[.-]*>\?\(\)*\.\?Add(' | grep -c 'Add(')"
ck 'NextInlineId call sites (excluding decl/defn)' 1 \
   "$(g 'NextInlineId' | grep -v 'intptr_t FlowGraphInliner::NextInlineId\|intptr_t NextInlineId' | wc -l | tr -d ' ')"
ck 'NextInlineId call site is in inliner.cc' 1 \
   "$(g 'NextInlineId' | grep -v 'intptr_t ' | grep -c 'backend/inliner.cc')"

# Claim C: the bypass gates.
ck 'TryInlineInstanceGetter gated on kImplicitGetter' 1 \
   "$(awk '/^bool CallSpecializer::TryInlineInstanceGetter/,/^}/' \
        "$T/vm/compiler/call_specializer.cc" | grep -c 'kind() != UntaggedFunction::kImplicitGetter')"
ck 'TryInlineInstanceSetter gated on kImplicitSetter' 1 \
   "$(awk '/^bool CallSpecializer::TryInlineInstanceSetter/,/^}/' \
        "$T/vm/compiler/call_specializer.cc" | grep -c 'kind() != UntaggedFunction::kImplicitSetter')"
ck 'TryInlineRecognizedMethod switches on recognized_kind' 1 \
   "$(awk '/^bool CallSpecializer::TryInlineRecognizedMethod/,/^}/' \
        "$T/vm/compiler/call_specializer.cc" | grep -c 'const MethodRecognizer::Kind kind = target.recognized_kind();')"

# recognized_kind is assigned in exactly one real place (plus the kUnknown
# default in Function::New).
ck 'set_recognized_kind assignments (non-default)' 1 \
   "$(g 'set_recognized_kind(' | grep -v 'kUnknown\|void Function::set_recognized_kind\|  void set_recognized_kind' | wc -l | tr -d ' ')"
ck 'that assignment is in method_recognizer.cc' 1 \
   "$(g 'set_recognized_kind(' | grep -v 'kUnknown\|void Function::' | grep -c 'compiler/method_recognizer.cc')"
ck 'vm:recognized is a DEBUG check, not an assignment' 1 \
   "$(awk '/^bool Function::CheckSourceFingerprint/,/^}/' "$T/vm/object.cc" \
        | grep -c 'IsMarkedAsRecognized')"

# The recognized library set must still be the closed built-in set.
EXPECT='AsyncLibrary CompactHashLibrary ConvertLibrary CoreLibrary DeveloperLibrary FfiLibrary InternalLibrary IsolateLibrary MathLibrary NativeWrappersLibrary TypedDataLibrary VMLibrary'
GOT=$(grep -ohE 'V\([A-Za-z]+Library,' "$T/vm/compiler/recognized_methods_list.h" \
        | sed 's/V(//;s/,//' | sort -u | tr '\n' ' ' | sed 's/ $//')
ck 'recognized library set unchanged' "$EXPECT" "$GOT"

echo
if [ "$fail" = 0 ]; then
  echo 'SM1_G5_RECORDER_COMPLETENESS: ENUMERATION_HOLDS'
else
  echo 'SM1_G5_RECORDER_COMPLETENESS: ENUMERATION_DRIFTED'
fi
exit "$fail"
