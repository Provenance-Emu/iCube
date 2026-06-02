// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// VertexLoaderNEON: AOT (ahead-of-time) NEON-SIMD CPU vertex loader for ARM64.
//
// This is the jitless replacement for VertexLoaderARM64 on iOS. Unlike
// VertexLoaderARM64 (which derives from Arm64Gen::ARM64CodeBlock and emits
// runtime machine code into a writable-executable page), this loader uses
// ordinary compiled NEON intrinsics selected from compile-time static tables.
// NO Arm64Emitter, NO ARM64CodeBlock, NO writable-exec pages -> App-Store legal.
//
// Architecture (composition, NOT a VertexLoader subclass):
//   * Owns a VertexLoader m_ctx as a *context object*. TPipelineFunction is
//     void(*)(VertexLoader*); every attribute decoder reads loader->m_posScale,
//     m_remaining, m_tcIndex, m_colIndex, m_curtexmtx[], m_texmtxread/write,
//     m_vertexSkip, m_skippedVertices. We reuse that context wholesale.
//   * m_ctx's ctor runs CompileVertexTranslator(), which fills m_ctx's
//     m_native_vtx_decl and the scale factors. We memcpy the decl from it so it
//     is byte-identical (VertexLoaderTester / Compare asserts on stride +
//     decl + every cache).
//   * We build our OWN Common::SmallVector<TPipelineFunction, 30> by replicating
//     the exact WriteCall *sequence* of CompileVertexTranslator (its stage
//     vector is private, so we cannot copy it; we reproduce the order).
//     Phase 1: every slot is the scalar pointer from VertexLoader_*::GetFunction
//     -> Compare passes immediately, proving the harness path before any SIMD.
//     Phase 2: direct (non-indexed) position/color/texcoord slots are swapped
//     for NEON functors that take VertexLoader* and operate on &m_ctx, so the
//     stage list stays homogeneous and "indexed -> scalar fallback" is literally
//     "leave the scalar pointer in place".

#pragma once

#include "Common/CommonTypes.h"
#include "Common/SmallVector.h"
#include "VideoCommon/VertexLoader.h"  // VertexLoader, TPipelineFunction
#include "VideoCommon/VertexLoaderBase.h"

class VertexLoaderNEON final : public VertexLoaderBase
{
public:
  VertexLoaderNEON(const TVtxDesc& vtx_desc, const VAT& vtx_attr);

  int RunVertices(const u8* src, u8* dst, int count) override;

private:
  // Reproduces CompileVertexTranslator's WriteCall sequence into m_pipeline,
  // choosing NEON functors for supported direct attributes and falling back to
  // the scalar VertexLoader_*::GetFunction pointer otherwise.
  void BuildPipeline();
  void WriteCall(TPipelineFunction func) { m_pipeline.push_back(func); }

  // Context object: holds m_posScale / m_tcScale[] / m_remaining / m_tcIndex /
  // m_colIndex / m_curtexmtx[] / m_texmtxread / m_texmtxwrite / m_vertexSkip /
  // m_skippedVertices that the attribute decoders read & mutate. Its ctor also
  // computes the canonical m_native_vtx_decl we copy.
  VertexLoader m_ctx;

  // Our own pipeline (same max-30 bound as VertexLoader; see VertexLoader.h:46).
  Common::SmallVector<TPipelineFunction, 30> m_pipeline;
};
