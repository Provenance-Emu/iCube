// Copyright 2016 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "VideoBackends/Vulkan/VKVertexFormat.h"

#include "Common/Assert.h"
#include "Common/EnumMap.h"

#include "VideoBackends/Vulkan/CommandBufferManager.h"
#include "VideoBackends/Vulkan/ObjectCache.h"

#include "VideoCommon/VertexLoaderManager.h"
#include "VideoCommon/VertexShaderGen.h"

namespace Vulkan
{
static VkFormat VarToVkFormat(ComponentFormat t, uint32_t components, bool integer)
{
  using ComponentArray = std::array<VkFormat, 4>;
  static constexpr auto f = [](ComponentArray a) { return a; };  // Deduction helper

  static constexpr Common::EnumMap<ComponentArray, ComponentFormat::InvalidFloat7>
      float_type_lookup = {
          f({VK_FORMAT_R8_UNORM, VK_FORMAT_R8G8_UNORM, VK_FORMAT_R8G8B8_UNORM,
             VK_FORMAT_R8G8B8A8_UNORM}),  // UByte
          f({VK_FORMAT_R8_SNORM, VK_FORMAT_R8G8_SNORM, VK_FORMAT_R8G8B8_SNORM,
             VK_FORMAT_R8G8B8A8_SNORM}),  // Byte
          f({VK_FORMAT_R16_UNORM, VK_FORMAT_R16G16_UNORM, VK_FORMAT_R16G16B16_UNORM,
             VK_FORMAT_R16G16B16A16_UNORM}),  // UShort
          f({VK_FORMAT_R16_SNORM, VK_FORMAT_R16G16_SNORM, VK_FORMAT_R16G16B16_SNORM,
             VK_FORMAT_R16G16B16A16_SNORM}),  // Short
          f({VK_FORMAT_R32_SFLOAT, VK_FORMAT_R32G32_SFLOAT, VK_FORMAT_R32G32B32_SFLOAT,
             VK_FORMAT_R32G32B32A32_SFLOAT}),  // Float
          f({VK_FORMAT_R32_SFLOAT, VK_FORMAT_R32G32_SFLOAT, VK_FORMAT_R32G32B32_SFLOAT,
             VK_FORMAT_R32G32B32A32_SFLOAT}),  // Invalid
          f({VK_FORMAT_R32_SFLOAT, VK_FORMAT_R32G32_SFLOAT, VK_FORMAT_R32G32B32_SFLOAT,
             VK_FORMAT_R32G32B32A32_SFLOAT}),  // Invalid
          f({VK_FORMAT_R32_SFLOAT, VK_FORMAT_R32G32_SFLOAT, VK_FORMAT_R32G32B32_SFLOAT,
             VK_FORMAT_R32G32B32A32_SFLOAT}),  // Invalid
      };

  static constexpr Common::EnumMap<ComponentArray, ComponentFormat::InvalidFloat7>
      integer_type_lookup = {
          f({VK_FORMAT_R8_UINT, VK_FORMAT_R8G8_UINT, VK_FORMAT_R8G8B8_UINT,
             VK_FORMAT_R8G8B8A8_UINT}),  // UByte
          f({VK_FORMAT_R8_SINT, VK_FORMAT_R8G8_SINT, VK_FORMAT_R8G8B8_SINT,
             VK_FORMAT_R8G8B8A8_SINT}),  // Byte
          f({VK_FORMAT_R16_UINT, VK_FORMAT_R16G16_UINT, VK_FORMAT_R16G16B16_UINT,
             VK_FORMAT_R16G16B16A16_UINT}),  // UShort
          f({VK_FORMAT_R16_SINT, VK_FORMAT_R16G16_SINT, VK_FORMAT_R16G16B16_SINT,
             VK_FORMAT_R16G16B16A16_SINT}),  // Short
          f({VK_FORMAT_R32_SFLOAT, VK_FORMAT_R32G32_SFLOAT, VK_FORMAT_R32G32B32_SFLOAT,
             VK_FORMAT_R32G32B32A32_SFLOAT}),  // Float
          f({VK_FORMAT_R32_SFLOAT, VK_FORMAT_R32G32_SFLOAT, VK_FORMAT_R32G32B32_SFLOAT,
             VK_FORMAT_R32G32B32A32_SFLOAT}),  // Invalid
          f({VK_FORMAT_R32_SFLOAT, VK_FORMAT_R32G32_SFLOAT, VK_FORMAT_R32G32B32_SFLOAT,
             VK_FORMAT_R32G32B32A32_SFLOAT}),  // Invalid
          f({VK_FORMAT_R32_SFLOAT, VK_FORMAT_R32G32_SFLOAT, VK_FORMAT_R32G32B32_SFLOAT,
             VK_FORMAT_R32G32B32A32_SFLOAT}),  // Invalid
      };

  ASSERT(components > 0 && components <= 4);
  return integer ? integer_type_lookup[t][components - 1] : float_type_lookup[t][components - 1];
}

VertexFormat::VertexFormat(const PortableVertexDeclaration& vtx_decl) : NativeVertexFormat(vtx_decl)
{
  MapAttributes();
  SetupInputState();
}

const VkPipelineVertexInputStateCreateInfo& VertexFormat::GetVertexInputStateInfo() const
{
  return m_input_state_info;
}

void VertexFormat::MapAttributes()
{
  m_num_attributes = 0;

  if (m_decl.position.enable)
    AddAttribute(
        ShaderAttrib::Position, 0,
        VarToVkFormat(m_decl.position.type, m_decl.position.components, m_decl.position.integer),
        m_decl.position.offset);

  for (uint32_t i = 0; i < 3; i++)
  {
    if (m_decl.normals[i].enable)
      AddAttribute(ShaderAttrib::Normal + i, 0,
                   VarToVkFormat(m_decl.normals[i].type, m_decl.normals[i].components,
                                 m_decl.normals[i].integer),
                   m_decl.normals[i].offset);
  }

  for (uint32_t i = 0; i < 2; i++)
  {
    if (m_decl.colors[i].enable)
      AddAttribute(ShaderAttrib::Color0 + i, 0,
                   VarToVkFormat(m_decl.colors[i].type, m_decl.colors[i].components,
                                 m_decl.colors[i].integer),
                   m_decl.colors[i].offset);
  }

  for (uint32_t i = 0; i < 8; i++)
  {
    if (m_decl.texcoords[i].enable)
      AddAttribute(ShaderAttrib::TexCoord0 + i, 0,
                   VarToVkFormat(m_decl.texcoords[i].type, m_decl.texcoords[i].components,
                                 m_decl.texcoords[i].integer),
                   m_decl.texcoords[i].offset);
  }

  if (m_decl.posmtx.enable)
    AddAttribute(ShaderAttrib::PositionMatrix, 0,
                 VarToVkFormat(m_decl.posmtx.type, m_decl.posmtx.components, m_decl.posmtx.integer),
                 m_decl.posmtx.offset);
}

void VertexFormat::SetupInputState()
{
  m_binding_description.binding = 0;

  // Compute stride as max(declared, largest attribute end), align to 4 bytes
  auto formatSize = [](VkFormat f) -> uint32_t {
    switch (f) {
      case VK_FORMAT_R8_UNORM: case VK_FORMAT_R8_SNORM: case VK_FORMAT_R8_UINT: case VK_FORMAT_R8_SINT: return 1;
      case VK_FORMAT_R8G8_UNORM: case VK_FORMAT_R8G8_SNORM: case VK_FORMAT_R8G8_UINT: case VK_FORMAT_R8G8_SINT: return 2;
      case VK_FORMAT_R8G8B8A8_UNORM: case VK_FORMAT_R8G8B8A8_SNORM: case VK_FORMAT_R8G8B8A8_UINT: case VK_FORMAT_R8G8B8A8_SINT: return 4;
      case VK_FORMAT_B8G8R8A8_UNORM: return 4;
      case VK_FORMAT_R16_UNORM: case VK_FORMAT_R16_SNORM: case VK_FORMAT_R16_UINT: case VK_FORMAT_R16_SINT: case VK_FORMAT_R16_SFLOAT: return 2;
      case VK_FORMAT_R16G16_UNORM: case VK_FORMAT_R16G16_SNORM: case VK_FORMAT_R16G16_UINT: case VK_FORMAT_R16G16_SINT: case VK_FORMAT_R16G16_SFLOAT: return 4;
      case VK_FORMAT_R16G16B16A16_UNORM: case VK_FORMAT_R16G16B16A16_SNORM: case VK_FORMAT_R16G16B16A16_UINT: case VK_FORMAT_R16G16B16A16_SINT: case VK_FORMAT_R16G16B16A16_SFLOAT: return 8;
      case VK_FORMAT_R32_SFLOAT: case VK_FORMAT_R32_UINT: case VK_FORMAT_R32_SINT: return 4;
      case VK_FORMAT_R32G32_SFLOAT: case VK_FORMAT_R32G32_UINT: case VK_FORMAT_R32G32_SINT: return 8;
      case VK_FORMAT_R32G32B32_SFLOAT: case VK_FORMAT_R32G32B32_UINT: case VK_FORMAT_R32G32B32_SINT: return 12;
      case VK_FORMAT_R32G32B32A32_SFLOAT: case VK_FORMAT_R32G32B32A32_UINT: case VK_FORMAT_R32G32B32A32_SINT: return 16;
      default: return 4;
    }
  };
  uint32_t max_end = 0;
  for (uint32_t i = 0; i < m_num_attributes; ++i)
  {
    const auto& a = m_attribute_descriptions[i];
    uint32_t end = a.offset + formatSize(a.format);
    if (end > max_end) max_end = end;
  }
  uint32_t computed_stride = m_decl.stride;
  if (max_end > computed_stride) computed_stride = max_end;
  // Align to 4 for safety
  computed_stride = (computed_stride + 3u) & ~3u;

  m_binding_description.stride = computed_stride;
  m_binding_description.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

  m_input_state_info.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
  m_input_state_info.pNext = nullptr;
  m_input_state_info.flags = 0;
  m_input_state_info.vertexBindingDescriptionCount = 1;
  m_input_state_info.pVertexBindingDescriptions = &m_binding_description;
  m_input_state_info.vertexAttributeDescriptionCount = m_num_attributes;
  m_input_state_info.pVertexAttributeDescriptions = m_attribute_descriptions.data();
}

void VertexFormat::AddAttribute(ShaderAttrib location, uint32_t binding, VkFormat format,
                                uint32_t offset)
{
  ASSERT(m_num_attributes < MAX_VERTEX_ATTRIBUTES);

  m_attribute_descriptions[m_num_attributes].location = static_cast<uint32_t>(location);
  m_attribute_descriptions[m_num_attributes].binding = binding;
  m_attribute_descriptions[m_num_attributes].format = format;
  m_attribute_descriptions[m_num_attributes].offset = offset;
  m_num_attributes++;
}
}  // namespace Vulkan
