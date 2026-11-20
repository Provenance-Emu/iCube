// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <array>
#include <vector>

#include <gtest/gtest.h>

#include "Common/CommonTypes.h"
#include "VideoCommon/CPMemory.h"
#include "VideoCommon/OpcodeDecoding.h"

// The test runner's alert handler (UnitTestsMain.cpp) fails the running test on any alert, so an
// assert in the decoder shows up as a failure here without a handler of our own.
namespace
{
struct XFLoad
{
  u16 address;
  u8 count;
};

class RecordingCallback final : public OpcodeDecoder::Callback
{
public:
  OPCODE_CALLBACK(void OnXF(u16 address, u8 count, const u8* data))
  {
    xf_loads.push_back({address, count});
  }
  OPCODE_CALLBACK(void OnInvalidXFLoad(u32 cmd2, const u8* data))
  {
    invalid_xf_loads.push_back(cmd2);
  }
  OPCODE_CALLBACK(void OnCP(u8 command, u32 value)) {}
  OPCODE_CALLBACK(void OnBP(u8 command, u32 value)) {}
  OPCODE_CALLBACK(void OnIndexedLoad(CPArray array, u32 index, u16 address, u8 size)) {}
  OPCODE_CALLBACK(void OnPrimitiveCommand(OpcodeDecoder::Primitive primitive, u8 vat,
                                          u32 vertex_size, u16 num_vertices, const u8* vertex_data))
  {
  }
  OPCODE_CALLBACK(void OnDisplayList(u32 address, u32 size)) {}
  OPCODE_CALLBACK(void OnNop(u32 count)) {}
  OPCODE_CALLBACK(void OnUnknown(u8 opcode, const u8* data)) {}
  OPCODE_CALLBACK(void OnCommand(const u8* data, u32 size)) {}
  OPCODE_CALLBACK(CPState& GetCPState()) { return m_cpmem; }
  OPCODE_CALLBACK(u32 GetVertexSize(u8 vat)) { return 0; }

  std::vector<XFLoad> xf_loads;
  std::vector<u32> invalid_xf_loads;

private:
  CPState m_cpmem;
};

}  // namespace

TEST(OpcodeDecodingTest, XFLoadDecodesAddressAndCount)
{
  // GX_LOAD_XF_REG, count - 1 = 1, address 0x1018, then two values.
  const std::array<u8, 13> stream{0x10, 0x00, 0x01, 0x10, 0x18, 0, 0, 0, 1, 0, 0, 0, 2};
  RecordingCallback callback;

  const u32 size = OpcodeDecoder::RunCommand(stream.data(), u32(stream.size()), callback);

  EXPECT_EQ(size, 13u);
  ASSERT_EQ(callback.xf_loads.size(), 1u);
  EXPECT_EQ(callback.xf_loads[0].address, 0x1018);
  EXPECT_EQ(callback.xf_loads[0].count, 2);
  EXPECT_TRUE(callback.invalid_xf_loads.empty());
}

// A count that does not fit the 4-bit field only comes from a garbage stream (the emulated GPU
// fell out of step with the CPU, or the game crashed). The words below were taken from ICUBE-BF
// and ICUBE-2Y reports. That is guest data: it must not raise the "Ignore and continue?" assert,
// whose "No" answer traps the app. The callback is told instead.
TEST(OpcodeDecodingTest, OversizedXFLoadCountIsReportedNotAsserted)
{
  for (const u32 cmd2 : {0x00616600u, 0x00FFFFFFu, 0x01303F19u, 0x38420004u})
  {
    SCOPED_TRACE(testing::Message() << "cmd2 = 0x" << std::hex << cmd2);
    std::array<u8, 5 + 16 * 4> stream{};
    stream[0] = 0x10;
    stream[1] = u8(cmd2 >> 24);
    stream[2] = u8(cmd2 >> 16);
    stream[3] = u8(cmd2 >> 8);
    stream[4] = u8(cmd2);
    RecordingCallback callback;

    const u32 size = OpcodeDecoder::RunCommand(stream.data(), u32(stream.size()), callback);

    // Only the low four bits of the count are decoded, as before.
    const u8 expected_count = u8(((cmd2 >> 16) & 0xf) + 1);
    EXPECT_EQ(callback.invalid_xf_loads, std::vector<u32>{cmd2});
    EXPECT_EQ(size, 5u + expected_count * 4u);
    ASSERT_EQ(callback.xf_loads.size(), 1u);
    EXPECT_EQ(callback.xf_loads[0].address, u16(cmd2));
    EXPECT_EQ(callback.xf_loads[0].count, expected_count);
  }
}

TEST(OpcodeDecodingTest, LargestXFLoadCountIsValid)
{
  // count - 1 = 15: sixteen values, the most the field can express.
  std::array<u8, 5 + 16 * 4> stream{};
  stream[0] = 0x10;
  stream[2] = 0x0f;
  RecordingCallback callback;

  const u32 size = OpcodeDecoder::RunCommand(stream.data(), u32(stream.size()), callback);

  EXPECT_EQ(size, 5u + 16u * 4u);
  ASSERT_EQ(callback.xf_loads.size(), 1u);
  EXPECT_EQ(callback.xf_loads[0].count, 16);
  EXPECT_TRUE(callback.invalid_xf_loads.empty());
}

// A command whose data has not all arrived is decoded again later, so it is not reported yet.
TEST(OpcodeDecodingTest, TruncatedOversizedXFLoadWaitsForItsData)
{
  // cmd2 = 0x00FF1000: count field 0xFF, sixteen values once masked, but only one is here.
  const std::array<u8, 9> stream{0x10, 0x00, 0xff, 0x10, 0x00, 0, 0, 0, 1};
  RecordingCallback callback;

  const u32 size = OpcodeDecoder::RunCommand(stream.data(), u32(stream.size()), callback);

  EXPECT_EQ(size, 0u);
  EXPECT_TRUE(callback.xf_loads.empty());
  EXPECT_TRUE(callback.invalid_xf_loads.empty());
}
