# Create the wrapper library with our iOS-specific code
add_library(dolphin SHARED
  Host.mm
  HostQueue.h
  HostQueue.mm
)

# Add necessary include directories
target_include_directories(dolphin PRIVATE
  ${CMAKE_SOURCE_DIR}/Source/Core
  ${CMAKE_SOURCE_DIR}/Externals/fmt/include
)

# Link with necessary libraries
target_link_libraries(dolphin
PUBLIC
  common
  core
  uicommon
  inputcommon
  discio
  audiocommon
  videocommon
  videovulkan
  videometal
  videoogl
  videosoftware
  videonull
  fmt::fmt
  MbedTLS::mbedtls
  MbedTLS::mbedcrypto
  MbedTLS::mbedx509
  BZip2::BZip2
  ZLIB::ZLIB
  minizip::minizip
  spng::spng
  enet::enet
  sfml-network
  sfml-system
  CURL::libcurl
  FatFs
  Iconv::Iconv
  rcheevos
  zstd
  xxhash
)

# Determine platform suffix based on PLATFORM variable
if(PLATFORM STREQUAL "OS64")
  set(PLATFORM_SUFFIX "-ios")
elseif(PLATFORM STREQUAL "SIMULATORARM64" OR PLATFORM STREQUAL "SIMULATOR64")
  set(PLATFORM_SUFFIX "-ios")
elseif(PLATFORM STREQUAL "TVOS")
  set(PLATFORM_SUFFIX "-tvos")
elseif(PLATFORM STREQUAL "SIMULATOR_TVOS")
  set(PLATFORM_SUFFIX "-tvos")
else()
  set(PLATFORM_SUFFIX "")
endif()

# Set properties for the dynamic library
set_target_properties(dolphin PROPERTIES
  OUTPUT_NAME "dolphin${PLATFORM_SUFFIX}"
  FRAMEWORK FALSE
  VERSION 1.0.0
  SOVERSION 1
  INSTALL_NAME_DIR "@rpath"
)

# Hide all symbols by default to avoid conflicts with other frameworks
set_target_properties(dolphin PROPERTIES
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  OBJC_VISIBILITY_PRESET hidden
  OBJCXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
)

# Add compile definitions to enable symbol isolation for glslang
target_compile_definitions(dolphin PRIVATE
    DOLPHIN_GLSLANG_ISOLATED=1
)

# Configure glslang to use custom symbol prefix
if(TARGET glslang)
    target_compile_definitions(glslang PRIVATE
        GLSLANG_SYMBOL_PREFIX=dolphin_
    )
endif()

# Also apply to SPIRV library if it exists
if(TARGET SPIRV)
    target_compile_definitions(SPIRV PRIVATE
        SPIRV_SYMBOL_PREFIX=dolphin_
    )
endif()

# Add aggressive compiler flags to prevent symbol conflicts with other frameworks
target_compile_options(dolphin PRIVATE
  "-fvisibility=hidden"
  "-fvisibility-inlines-hidden"
  "-Xclang" "-fmodules-local-submodule-visibility"
)

# Add linker flags to prevent symbol conflicts with other frameworks
target_link_options(dolphin PRIVATE
  "-Wl,-interposable"
  "-Wl,-unexported_symbol,_glslang*"
  "-Wl,-unexported_symbol,_SPIRV*"
)

# Force usage of bundled glslang by adding -Wl,-force_load option
target_link_options(dolphin PRIVATE
  "-Wl,-force_load,${CMAKE_BINARY_DIR}/Externals/glslang/libglslang.a"
  "-Wl,-dead_strip_dylibs"
  "-Wl,-reexport_library,${CMAKE_BINARY_DIR}/Externals/glslang/libglslang.a"
  "-Wl,-order_file,${CMAKE_CURRENT_SOURCE_DIR}/glslang_first.order"
)

# Add explicit link dependency on glslang to ensure it's built
target_link_libraries(dolphin PRIVATE glslang)

# Create an order file to prioritize bundled glslang symbols
add_custom_command(
  OUTPUT ${CMAKE_CURRENT_SOURCE_DIR}/glslang_first.order
  COMMAND echo "_glslang*" > ${CMAKE_CURRENT_SOURCE_DIR}/glslang_first.order
  COMMAND echo "_SPIRV*" >> ${CMAKE_CURRENT_SOURCE_DIR}/glslang_first.order
  VERBATIM
)

# Add aggressive compiler flags to prevent symbol conflicts with other frameworks
target_compile_options(dolphin PRIVATE
  "-fvisibility=hidden"
  "-fvisibility-inlines-hidden"
  "-Xclang" "-fmodules-local-submodule-visibility"
)

# Add linker flags to prevent symbol conflicts with other frameworks
target_link_options(dolphin PRIVATE
  "-Wl,-interposable"
  "-Wl,-unexported_symbol,_glslang*"
  "-Wl,-unexported_symbol,_SPIRV*"
)
