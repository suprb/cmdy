#include "cmdy_native.h"
#include "cmdy_engine_build.h"

#ifndef CMDY_ZIG_SELECTED_SOURCE_KEY
#error "CMDY native archive selection is missing. Build this bridge through Core/Package.swift."
#else
_Static_assert(__builtin_strcmp(CMDY_ZIG_SOURCE_KEY, CMDY_ZIG_SELECTED_SOURCE_KEY) == 0,
    "CMDY native archive selection changed. Use ./build.sh or add --manifest-cache none --disable-build-manifest-caching to SwiftPM.");
#endif

/* The generated include invalidates SwiftPM's C object when the native
   archive changes. This reference also makes the native backend inspectable. */
uint32_t cmdy_native_engine_abi_version(void) {
    return cmdy_zig_engine_abi_version();
}
const char *cmdy_native_engine_source_key(void) { return CMDY_ZIG_SOURCE_KEY; }
const char *cmdy_native_engine_build_mode(void) { return CMDY_ZIG_BUILD_MODE; }
