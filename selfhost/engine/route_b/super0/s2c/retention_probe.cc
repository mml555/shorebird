// 2C.0a.2 — which retention mechanism survives the pinned Clang + Mach-O
// -dead_strip (and LTO)? Nothing here is read.
extern "C" {

// 1. plain static const
static const char kPlain[] = "MARKER-PLAIN-shorebird-route-b-2c-candidate-v1";

// 2. used
__attribute__((used))
const char kUsed[] = "MARKER-USED-shorebird-route-b-2c-candidate-v1";

// 3. used + retain
#if defined(__clang__)
__attribute__((used, retain))
const char kRetain[] = "MARKER-RETAIN-shorebird-route-b-2c-candidate-v1";
#endif

// 4. used + Mach-O no_dead_strip SECTION attribute
__attribute__((used, section("__DATA,__shorebird,regular,no_dead_strip")))
const char kSection[] = "MARKER-SECTION-shorebird-route-b-2c-candidate-v1";

// 5. exported C-linkage symbol, used
__attribute__((used, visibility("default")))
const char kExported[] = "MARKER-EXPORTED-shorebird-route-b-2c-candidate-v1";
}

extern "C" int probe_entry() { return 0; }
