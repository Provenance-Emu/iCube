add_library(dolphin SHARED
  Host.mm
  HostQueue.h
  HostQueue.mm
)

## Inherit global linker flags; avoid per-target -all_load which breaks ThinLTO/bitcode

target_link_libraries(dolphin
PUBLIC
  common
  core
  uicommon
)

# Ensure UICommon symbols (Init/Shutdown/SetUserDirectory/CreateDirectories) are included
# in the shared library so they are available to consumers of the xcframework.
# Without this, the linker may omit unreferenced objects from the static archive
# when producing the shared lib, leading to undefined symbols in downstream apps.
if(APPLE)
  # Force-load only the UICommon archive (not global -all_load)
  target_link_options(dolphin PRIVATE "-Wl,-force_load,$<TARGET_FILE:uicommon>")
endif()
