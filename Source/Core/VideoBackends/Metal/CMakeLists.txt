add_library(videometal
  MRCHelpers.h
  MTLBoundingBox.mm
  MTLBoundingBox.h
  MTLGfx.mm
  MTLGfx.h
  MTLMain.mm
  MTLObjectCache.h
  MTLObjectCache.mm
  MTLPerfQuery.mm
  MTLPerfQuery.h
  MTLPipeline.mm
  MTLPipeline.h
  MTLShader.mm
  MTLShader.h
  MTLStateTracker.mm
  MTLStateTracker.h
  MTLTexture.mm
  MTLTexture.h
  MTLUtil.mm
  MTLUtil.h
  MTLVertexFormat.mm
  MTLVertexFormat.h
  MTLVertexManager.mm
  MTLVertexManager.h
  VideoBackend.h
)

# iCube: this (upstream) backend intentionally uses the pre-16 Metal reflection API
# (MTLArgument/MTLArgumentType/vertexArguments/MTLPipelineOptionArgumentInfo), which Apple deprecated
# at iOS/tvOS 16 in favor of MTLBinding — but upstream Dolphin still targets it for old-OS support, so
# we don't migrate ahead of upstream (it would also need @available branches below our deploy floor).
# It also memset/memcpy's a few POD-ish pipeline-id structs. Silence that noise locally rather than
# touching the upstream sources.
target_compile_options(videometal PRIVATE -Wno-deprecated-declarations -Wno-nontrivial-memcall)

find_library(METAL_LIBRARY Metal)
find_library(QUARTZCORE_LIBRARY QuartzCore)

target_link_libraries(videometal
PUBLIC
  common
  videocommon
PRIVATE
  spirv_cross
  ${FOUNDATION_LIBRARY}
  ${METAL_LIBRARY}
  ${QUARTZCORE_LIBRARY}
)

target_compile_options(videometal PRIVATE -fno-objc-arc)
