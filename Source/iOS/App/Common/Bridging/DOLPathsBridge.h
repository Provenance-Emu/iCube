#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Returns a C string path to the Dolphin StateSaves directory.
// The caller should copy the string immediately (do not store the pointer).
const char* DolphinGetStateSavesPathC(void);

// Returns a C string path to the Dolphin User directory — the root that every
// other user path (StateSaves, GC, Wii, Config, GameSettings) hangs off.
//
// WS-5 uses this as the root for CloudKit sync: every record name is a path
// relative to this directory, so it must come from Dolphin's own path system
// rather than being derived by walking up from another path. Dolphin's paths
// carry a trailing separator, and a parent-of-StateSaves derivation would
// silently re-root every record if that ever changed.
//
// The caller should copy the string immediately (do not store the pointer).
const char* DolphinGetUserPathC(void);

#ifdef __cplusplus
}
#endif
