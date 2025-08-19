#!/bin/bash

set -e

PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

REPO_ROOT_DIR="$PROJECT_DIR/../../.."
CMAKE_BUILD_DIR="$REPO_ROOT_DIR/build-$PLATFORM_NAME-$DOL_CORE_BUILD_TARGET"

MACHINE_ARCH="$(arch)"

case $PLATFORM_NAME in
    iphoneos)
        PLATFORM=OS64
        PLATFORM_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET
        ;;
    iphonesimulator)
        if [ "$MACHINE_ARCH" = "arm64" ]; then
            PLATFORM=SIMULATORARM64
        else
            PLATFORM=SIMULATOR64
        fi

        PLATFORM_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET
        ;;
    appletvos)
        PLATFORM=TVOS
        PLATFORM_DEPLOYMENT_TARGET=$TVOS_DEPLOYMENT_TARGET
        ;;
    appletvsimulator)
        PLATFORM=SIMULATOR_TVOS
        PLATFORM_DEPLOYMENT_TARGET=$TVOS_DEPLOYMENT_TARGET
        ;;
    *)
        echo "Unknown platform \"$PLATFORM_NAME\""
        exit 1
        ;;
esac

# Optional PGO support (set DOL_CORE_PGO=generate|use and DOL_CORE_PGO_PROFILE for use)
PGO_MODE="${DOL_CORE_PGO:-off}"
PGO_FLAGS_C=""
PGO_FLAGS_CXX=""
if [ "$PGO_MODE" = "generate" ]; then
    PGO_FLAGS_C="-fprofile-instr-generate -fcoverage-mapping"
    PGO_FLAGS_CXX="-fprofile-instr-generate -fcoverage-mapping"
elif [ "$PGO_MODE" = "use" ] && [ -n "$DOL_CORE_PGO_PROFILE" ]; then
    PGO_FLAGS_C="-fprofile-instr-use=$DOL_CORE_PGO_PROFILE"
    PGO_FLAGS_CXX="-fprofile-instr-use=$DOL_CORE_PGO_PROFILE"
fi

# CPU tuning flags per target arch
CPU_TUNE_FLAGS=""
case "$PLATFORM" in
  OS64|TVOS|SIMULATORARM64)
    CPU_TUNE_FLAGS="-mcpu=apple-a10 -mtune=apple-a14 -march=armv8-a+simd+crc+crypto"
    ;;
  *)
    CPU_TUNE_FLAGS=""
    ;;
esac

# Common compile flags
COMMON_C_FLAGS=" \
-Ofast \
-fvectorize \
-funsafe-math-optimizations \
-funroll-loops \
-ftree-vectorize \
-fsplit-lto-unit \
-freciprocal-math \
-fPIC \
-fpermissive \
-fomit-frame-pointer \
-fno-trapping-math \
-fno-strict-aliasing \
-fno-signed-zeros \
-fno-math-errno \
-flto=thin \
-finline-functions \
-ffunction-sections \
-ffp-contract=fast \
-ffinite-math-only \
-ffast-math \
-fdata-sections \
-fno-semantic-interposition \
${CPU_TUNE_FLAGS}"
COMMON_CXX_FLAGS="${COMMON_C_FLAGS} -fvisibility-inlines-hidden"

if [ ! -d "$CMAKE_BUILD_DIR" ]; then
    mkdir "$CMAKE_BUILD_DIR"
fi

cd "$CMAKE_BUILD_DIR"

if [ ! -f "$CMAKE_BUILD_DIR/build.ninja" ]; then
  cmake "$REPO_ROOT_DIR" \
    -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$REPO_ROOT_DIR/Externals/ios-cmake/ios.toolchain.cmake" \
    -DPLATFORM=$PLATFORM \
    -DDEPLOYMENT_TARGET=$PLATFORM_DEPLOYMENT_TARGET \
    -DENABLE_VISIBILITY=ON \
    -DENABLE_BITCODE=OFF \
    -DENABLE_ARC=ON \
    -DCMAKE_BUILD_TYPE=$DOL_CORE_BUILD_TARGET \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS} ${PGO_FLAGS_C}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS} ${PGO_FLAGS_CXX}" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-dead_strip -Wl,-dead_strip_dylibs" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-dead_strip -Wl,-dead_strip_dylibs" \
    -DIOS=ON \
    -DENABLE_ANALYTICS=NO \
    -DUSE_SYSTEM_LIBS=OFF \
    -DENABLE_TESTS=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
fi

ninja
