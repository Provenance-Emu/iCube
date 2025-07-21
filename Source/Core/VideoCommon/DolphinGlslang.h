// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

// Dolphin-specific glslang wrapper to avoid symbol conflicts with other frameworks
// This header wraps glslang in a unique namespace to prevent conflicts with PVAzahar/Citra

#define DOLPHIN_GLSLANG_NAMESPACE dolphin_glslang

// Wrap glslang in our own namespace
namespace DOLPHIN_GLSLANG_NAMESPACE {
    // Include glslang headers within our namespace
    #include "GlslangToSpv.h"
    #include "ResourceLimits.h"
    #include "disassemble.h"
}

// Create aliases in the global scope for easier usage
namespace dolphin_glslang = DOLPHIN_GLSLANG_NAMESPACE::glslang;
using dolphin_EShLanguage = DOLPHIN_GLSLANG_NAMESPACE::EShLanguage;
using dolphin_EShTargetLanguageVersion = DOLPHIN_GLSLANG_NAMESPACE::glslang::EShTargetLanguageVersion;
using dolphin_TBuiltInResource = DOLPHIN_GLSLANG_NAMESPACE::TBuiltInResource;

// Function aliases for commonly used glslang functions
namespace DolphinGlslang {
    inline bool InitializeProcess() {
        return DOLPHIN_GLSLANG_NAMESPACE::glslang::InitializeProcess();
    }
    
    inline void FinalizeProcess() {
        DOLPHIN_GLSLANG_NAMESPACE::glslang::FinalizeProcess();
    }
    
    inline const TBuiltInResource* GetDefaultTBuiltInResource() {
        return &DOLPHIN_GLSLANG_NAMESPACE::glslang::DefaultTBuiltInResource;
    }
    
    inline void GlslangToSpv(const DOLPHIN_GLSLANG_NAMESPACE::glslang::TIntermediate& intermediate, 
                            std::vector<unsigned int>& spirv,
                            DOLPHIN_GLSLANG_NAMESPACE::spv::SpvBuildLogger* logger = nullptr,
                            const DOLPHIN_GLSLANG_NAMESPACE::glslang::SpvOptions* options = nullptr) {
        DOLPHIN_GLSLANG_NAMESPACE::glslang::GlslangToSpv(intermediate, spirv, logger, options);
    }
}
