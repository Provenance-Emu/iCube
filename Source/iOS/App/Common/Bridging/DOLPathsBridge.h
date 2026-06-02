#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Returns a C string path to the Dolphin StateSaves directory.
// The caller should copy the string immediately (do not store the pointer).
const char* DolphinGetStateSavesPathC(void);

#ifdef __cplusplus
}
#endif
