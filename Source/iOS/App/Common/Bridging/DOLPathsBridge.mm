#import "DOLPathsBridge.h"

// C++ Dolphin headers
#include "Common/CommonPaths.h"
#include "Common/FileUtil.h"

extern "C" const char* DolphinGetStateSavesPathC(void) {
    // Retrieve the StateSaves directory path from Dolphin's path system.
    static std::string s_path = File::GetUserPath(D_STATESAVES_IDX);
    return s_path.c_str();
}

extern "C" const char* DolphinGetUserPathC(void) {
    // The User directory root. Dolphin returns it with a trailing separator;
    // NSURL/URL handle that fine, and callers that want a relative path go
    // through CanonicalRelativePath, which standardizes both sides anyway.
    static std::string s_path = File::GetUserPath(D_USER_IDX);
    return s_path.c_str();
}
