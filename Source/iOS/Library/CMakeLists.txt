add_library(dolphin SHARED
  Host.mm
  HostQueue.h
  HostQueue.mm
)

set_target_properties(dolphin PROPERTIES
  LINK_FLAGS "-Wl,-all_load"
)

target_link_libraries(dolphin
PUBLIC
  common
  core
  uicommon
)

# Second-pass link from BuildiOSXCFramework.py: a generated list of third-party weak symbols
# (fmt, glslang, SPIRV, ImGui, libc++) to keep private so dyld cannot coalesce them with
# another core framework's copies. Dolphin's own symbols stay exported for the PVDolphin bridge.
if(DOLPHIN_UNEXPORTED_SYMBOLS_LIST)
  target_link_options(dolphin PRIVATE "LINKER:-unexported_symbols_list,${DOLPHIN_UNEXPORTED_SYMBOLS_LIST}")
  set_property(TARGET dolphin APPEND PROPERTY LINK_DEPENDS "${DOLPHIN_UNEXPORTED_SYMBOLS_LIST}")
endif()
