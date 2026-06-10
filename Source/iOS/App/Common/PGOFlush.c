// iCube PGO flush shim — see PGOFlush.h.
//
// The __llvm_profile_* symbols are provided by libclang_rt.profile_* linked into the
// PVlibDolphin dylib ONLY when built with -fprofile-generate (DOL_PGO=generate). They are
// declared weak here so a non-instrumented (shipping) build links cleanly — the pointers are
// then NULL and every entry point degrades to a safe no-op.

#include "PGOFlush.h"

// weak_import (NOT plain weak): on Darwin/Mach-O this makes these *weak references* that
// resolve to NULL when the symbol is absent at link/load time. Plain __attribute__((weak)) is a
// weak *definition* and still link-errors as "Undefined symbol" when nothing defines it — which
// is exactly the normal (DOL_PGO=off) build, where the dylib carries no __llvm_profile_* runtime.
extern int __llvm_profile_write_file(void) __attribute__((weak_import));
extern void __llvm_profile_set_filename(const char* name) __attribute__((weak_import));

void ICubePGOSetPath(const char* path)
{
  if (__llvm_profile_set_filename && path)
    __llvm_profile_set_filename(path);
}

int ICubePGOFlush(void)
{
  if (!__llvm_profile_write_file)
    return -1;  // not an instrumented build
  return __llvm_profile_write_file();
}

int ICubePGOAvailable(void)
{
  return __llvm_profile_write_file != 0;
}
