#import "DOLPathsBridge.h"

// C++ Dolphin headers
#include "Common/CommonPaths.h"
#include "Common/FileUtil.h"

extern "C" const char* DolphinGetStateSavesPathC(void) {
    // Retrieve the StateSaves directory path from Dolphin's path system.
    static std::string s_path = File::GetUserPath(D_STATESAVES_IDX);
    return s_path.c_str();
}
