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
