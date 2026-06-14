set(ZLIB_ENABLE_TESTS OFF)
set(ZLIB_COMPAT ON)
set(SKIP_INSTALL_ALL ON)

option(BUILD_SHARED_LIBS "Build shared library" OFF)

# zlib-ng's WITH_SANITIZER valid values changed across versions: the old pin defaulted to AUTO,
# which newer zlib-ng rejects with a FATAL_ERROR ("Unknown WITH_SANITIZER option: 'auto'"). We never
# sanitize zlib-ng in release builds, so pin it OFF with FORCE — this overrides a stale CMakeCache
# value (e.g. AUTO left by an older pin) so configure can't fail on an incremental reconfigure.
set(WITH_SANITIZER OFF CACHE STRING "Enable sanitizer support" FORCE)

add_subdirectory(zlib-ng)

# Set ZLIB variables for find_package used by other projects
set(ZLIB_INCLUDE_DIR ${CMAKE_BINARY_DIR}/zlib-ng CACHE STRING "Path to zlib include directory")
set(ZLIB_LIBRARY ZLIB::ZLIB CACHE STRING "Path to zlib library")

# Setup zlib alias project so FindZLIB doesn't recreate it
add_library(ZLIB::ZLIB ALIAS zlib)
dolphin_disable_warnings(zlib)
