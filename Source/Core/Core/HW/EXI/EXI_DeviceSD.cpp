// Copyright 2020 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// From the unmerged upstream change "SD card adapter support" (dolphin-emu/dolphin#12680),
// cut down to one card: no Serial Port 2 slot and no per-slot image paths.

#include "Core/HW/EXI/EXI_DeviceSD.h"

#include <algorithm>
#include <array>
#include <cinttypes>
#include <string>

#include "Common/ChunkFile.h"
#include "Common/CommonTypes.h"
#include "Common/Config/Config.h"
#include "Common/FileUtil.h"
#include "Common/IOFile.h"
#include "Common/Logging/Log.h"

#include "Core/Config/MainSettings.h"
#include "Core/HW/Memmap.h"
#include "Core/System.h"

namespace ExpansionInterface
{
// CRC-7 and CRC-16-CCITT as the SD specification defines them (section 4.5).
static u8 HashCrc7(const u8* ptr, size_t length)
{
  constexpr u8 CRC_POLYNOMIAL = 0x09;
  u8 result = 0;
  for (size_t i = 0; i < length; i++)
  {
    result ^= ptr[i];
    for (int bit = 0; bit < 8; bit++)
      result = (result & 0x80) ? (result << 1) ^ (CRC_POLYNOMIAL << 1) : (result << 1);
  }
  return result >> 1;
}

static u16 HashCrc16(const u8* ptr, size_t length)
{
  constexpr u16 CRC_POLYNOMIAL = 0x1021;
  u16 result = 0;
  for (size_t i = 0; i < length; i++)
  {
    result ^= (ptr[i] << 8);
    for (int bit = 0; bit < 8; bit++)
      result = (result & 0x8000) ? (result << 1) ^ CRC_POLYNOMIAL : (result << 1);
  }
  return result;
}

template <size_t N>
static u16 HashCrc16(const std::array<u8, N>& data)
{
  return HashCrc16(data.data(), N);
}

// The Card-Specific Data register of a standard-capacity card (CSD version 1.0, section 5.3.2)
// holding `size` bytes. Its capacity is (C_SIZE + 1) << (C_SIZE_MULT + 2) blocks of
// 1 << READ_BL_LEN bytes, which reaches 1 GiB with 512-byte blocks and 2 GiB with 1024-byte
// ones; a size that does not fit is rounded down.
std::array<u8, 16> CEXISD::MakeCSD(u64 size)
{
  constexpr u64 GIBIBYTE = 1024 * 1024 * 1024;
  const u32 block_len = size > GIBIBYTE ? 10 : 9;
  constexpr u32 c_size_mult = 7;
  const u64 units = size >> (block_len + c_size_mult + 2);
  const u32 c_size = static_cast<u32>(std::clamp<u64>(units, 1, 4096) - 1);

  // Command classes 0, 2, 4, 5, 7 and 8. Not class 10 (switch function): the card has one speed.
  constexpr u32 ccc = 0x1b5;

  std::array<u8, 16> csd = {
      0x00,                                        // CSD_STRUCTURE 0, reserved
      0x26,                                        // TAAC: 1.5 ms
      0x00,                                        // NSAC
      0x32,                                        // TRAN_SPEED: 25 Mbit/s
      static_cast<u8>(ccc >> 4),                   // CCC, high 8 bits
      static_cast<u8>((ccc << 4) | block_len),     // CCC low 4 bits, READ_BL_LEN
      static_cast<u8>(0x80 | (c_size >> 10)),      // READ_BL_PARTIAL, C_SIZE high 2 bits
      static_cast<u8>(c_size >> 2),                // C_SIZE
      static_cast<u8>((c_size << 6) | 0x3f),       // C_SIZE low 2 bits, VDD_R_CURR
      static_cast<u8>(0xfc | (c_size_mult >> 1)),  // VDD_W_CURR, C_SIZE_MULT high 2 bits
      static_cast<u8>((c_size_mult << 7) | 0x7f),  // C_SIZE_MULT low bit, ERASE_BLK_EN,
                                                   // SECTOR_SIZE
      0x80,                                        // SECTOR_SIZE low bit, WP_GRP_SIZE
      static_cast<u8>(0x04 | (block_len >> 2)),    // R2W_FACTOR 1, WRITE_BL_LEN high 2 bits
      static_cast<u8>(block_len << 6),             // WRITE_BL_LEN low 2 bits
      0x00,                                        // file format: hard disk like
      0x00,
  };
  csd[15] = static_cast<u8>((HashCrc7(csd.data(), 15) << 1) | 1);
  return csd;
}

CEXISD::CEXISD(Core::System& system) : IEXIDevice(system)
{
  // No image is no card: an empty adapter, which a program sees as an empty slot.
  const std::string filename = Config::Get(Config::MAIN_GC_SD_CARD_PATH);
  if (filename.empty())
    return;

  if (!m_card.Open(filename, "r+b"))
    ERROR_LOG_FMT(EXPANSIONINTERFACE, "Could not open SD card image {}", filename);
}

void CEXISD::ImmWrite(u32 data, u32 size)
{
  while (size--)
  {
    u8 byte = data >> 24;
    WriteByte(byte);
    data <<= 8;
  }
}

u32 CEXISD::ImmRead(u32 size)
{
  u32 res = 0;
  u32 position = 0;
  while (size--)
  {
    u8 byte = ReadByte();
    res |= byte << (24 - (position++ * 8));
  }
  return res;
}

void CEXISD::ImmReadWrite(u32& data, u32 size)
{
  ImmWrite(data, size);
  data = ImmRead(size);
}

void CEXISD::DMAWrite(u32 address, u32 size)
{
  auto& memory = m_system.GetMemory();
  while (size--)
    WriteByte(memory.Read_U8(address++));
}

void CEXISD::DMARead(u32 address, u32 size)
{
  auto& memory = m_system.GetMemory();
  while (size--)
    memory.Write_U8(ReadByte(), address++);
}

bool CEXISD::IsPresent() const
{
  return m_card.IsOpen();
}

void CEXISD::DoState(PointerWrap& p)
{
  p.Do(state);
  p.Do(command_position);
  p.DoArray(command_buffer);
  p.Do(response);
  p.Do(block_position);
  p.DoArray(block_buffer);
  p.Do(address);
  p.Do(block_crc);
  p.Do(m_idle);
}

void CEXISD::WriteByte(u8 byte)
{
  if (state == State::SingleBlockRead || state == State::MultipleBlockRead)
  {
    WriteForBlockRead(byte);
  }
  else if (state == State::SingleBlockWrite || state == State::MultipleBlockWrite)
  {
    WriteForBlockWrite(byte);
  }
  else
  {
    // TODO: Write-protect inversion(?)
    if (command_position == 0)
    {
      if ((byte & 0b11000000) == 0b01000000)
      {
        INFO_LOG_FMT(EXPANSIONINTERFACE, "EXI SD command started: {:02x}", byte);
        command_buffer[command_position++] = byte;
      }
    }
    else if (command_position < 6)
    {
      command_buffer[command_position++] = byte;

      if (command_position == 6)
      {
        // Buffer now full
        command_position = 0;

        if ((byte & 1) == 0)
        {
          WARN_LOG_FMT(EXPANSIONINTERFACE, "EXI SD command invalid, missing end bit: got {:02x}",
                       byte);
          // Guessed behavior; I'm not sure if this is actually what should be done
          response.push_back(static_cast<u8>(R1::CommunicationCRCError));
          return;
        }

        // Per § 7.2.2 Bus Transfer Protection, the CRC is actually optional in SPI mode and
        // defaults to disabled (except for the inital GoIdleState command, which is technically in
        // SD mode, and SendInterfaceCond, which presumably was deemed important enough due to
        // containing voltage information).

        // Datel, being datel, doesn't include a CRC, instead sending 0xff when a CRC is not
        // required. Libogc and Nintendo titles also don't enable CRCs, but still send correct ones.
        u8 hash = (HashCrc7(command_buffer.data(), 5) << 1) | 1;
        if (byte != hash)
        {
          Command command = static_cast<Command>(command_buffer[0] & 0x3f);

          if (byte != 0xff || command == Command::GoIdleState ||
              command == Command::SendInterfaceCond)
          {
            WARN_LOG_FMT(EXPANSIONINTERFACE,
                         "EXI SD command invalid, incorrect CRC7: got {:02x}, should be {:02x}",
                         byte, hash);
            response.push_back(static_cast<u8>(R1::CommunicationCRCError));
            return;
          }
          else
          {
            WARN_LOG_FMT(EXPANSIONINTERFACE,
                         "EXI SD command invalid, incorrect CRC7: got {:02x}, should be {:02x}"
                         "; ignoring because Datel doesn't include a CRC",
                         byte, hash);
          }
        }

        u8 command = command_buffer[0] & 0x3f;
        u32 argument = command_buffer[1] << 24 | command_buffer[2] << 16 | command_buffer[3] << 8 |
                       command_buffer[4];

        INFO_LOG_FMT(EXPANSIONINTERFACE, "EXI SD command received: {:02x} {:08x}", command,
                     argument);

        if (state == State::ReadyForAppCommand)
        {
          state = State::ReadyForCommand;
          HandleAppCommand(static_cast<AppCommand>(command), argument);
        }
        else
        {
          HandleCommand(static_cast<Command>(command), argument);
        }
      }
    }
  }
}

void CEXISD::HandleCommand(Command command, u32 argument)
{
  switch (command)
  {
  case Command::GoIdleState:
    m_idle = true;
    response.push_back(static_cast<u8>(R1::InIdleState));
    break;
  case Command::SendOpCond:
  {
    // Used by libogc for non-SDHC cards
    bool hcs = argument & (1 << 30);  // Host Capacity Support (for SDHC/SDXC cards)
    INFO_LOG_FMT(EXPANSIONINTERFACE, "SD Host Capacity Support: {}", hcs);
    m_idle = false;
    response.push_back(0);  // R1 - not idle
    break;
  }
  case Command::SendInterfaceCond:
  {
    u8 supply_voltage = (argument >> 8) & 0xf;
    u8 check_pattern = argument & 0xff;
    // Format R7
    response.push_back(static_cast<u8>(R1::InIdleState));  // R1
    response.push_back(0);                                 // Command version nybble (0), reserved
    response.push_back(0);                                 // Reserved
    response.push_back(supply_voltage);                    // Reserved + voltage
    response.push_back(check_pattern);
    break;
  }
  case Command::SendCSD:
  {
    const std::array<u8, 16> csd = MakeCSD(m_card.GetSize());
    // R1
    response.push_back(0);
    // Data ready token
    response.push_back(START_BLOCK);
    for (auto byte : csd)
      response.push_back(byte);

    u16 crc16 = HashCrc16(csd);
    response.push_back(crc16 >> 8);
    response.push_back(crc16);
    break;
  }
  case Command::SendCID:
  {
    // R1
    response.push_back(0);
    // Data ready token
    response.push_back(START_BLOCK);
    // The CID -- no idea what the format is, copied from SDIOSlot0
    std::array<u8, 16> cid = {
        0x80, 0x11, 0x4d, 0x1c, 0x80, 0x08, 0x00, 0x00,
        0x80, 0x07, 0xb5, 0x20, 0x80, 0x08, 0x00, 0x00,
    };
    for (auto byte : cid)
      response.push_back(byte);

    u16 crc16 = HashCrc16(cid);
    response.push_back(crc16 >> 8);
    response.push_back(crc16);
    break;
  }
  case Command::StopTransmission:
    response.push_back(0);  // R1
    // There can be further padding bytes, but it's not needed
    break;
  case Command::SendStatus:
    response.push_back(0);  // R1
    response.push_back(0);  // R2
    break;
  case Command::SetBlockLen:
    INFO_LOG_FMT(EXPANSIONINTERFACE, "Set blocklen to {}", argument);
    // TODO: error if blocklen not 512
    response.push_back(0);  // R1
    break;
  case Command::AppCmd:
    state = State::ReadyForAppCommand;
    response.push_back(0);  // R1
    break;
  case Command::ReadSingleBlock:
    state = State::SingleBlockRead;
    block_state = BlockState::Response;
    address = argument;
    break;
  case Command::ReadMultipleBlock:
    state = State::MultipleBlockRead;
    block_state = BlockState::Response;
    address = argument;
    break;
  case Command::WriteSingleBlock:
    state = State::SingleBlockWrite;
    block_state = BlockState::Response;
    address = argument;
    break;
  case Command::WriteMultipleBlock:
    state = State::MultipleBlockWrite;
    block_state = BlockState::Response;
    address = argument;
    break;
  case Command::CRCOnOff:
    // Every reply already carries a correct CRC, and nothing a program sends is rejected for
    // a wrong one, so there is nothing to switch.
    response.push_back(m_idle ? static_cast<u8>(R1::InIdleState) : 0);
    break;
  case Command::ReadOCR:
  {
    response.push_back(0);  // R1
    u32 ocr = OCR_DEFAULT.m_hex;
    response.push_back(ocr >> 24);
    response.push_back(ocr >> 16);
    response.push_back(ocr >> 8);
    response.push_back(ocr);
    break;
  }
  default:
    // Don't know it
    WARN_LOG_FMT(EXPANSIONINTERFACE, "Unimplemented SD command {:02x} {:08x}",
                 static_cast<u8>(command), argument);
    response.push_back(static_cast<u8>(R1::IllegalCommand));
  }
}

void CEXISD::HandleAppCommand(AppCommand app_command, u32 argument)
{
  switch (app_command)
  {
  case AppCommand::SDStatus:
  {
    response.push_back(0);  // R1
    response.push_back(0);  // R2
    // Data ready token
    response.push_back(START_BLOCK);
    // All-zero for now
    std::array<u8, 64> status = {};
    for (auto byte : status)
    {
      response.push_back(byte);
    }

    u16 crc16 = HashCrc16(status);
    response.push_back(crc16 >> 8);
    response.push_back(crc16);
    break;
  }
  case AppCommand::SDSendOpCond:
  {
    // Used by Pokémon Channel for all cards, and libogc for SDHC cards
    bool hcs = argument & (1 << 30);  // Host Capacity Support (for SDHC/SDXC cards)
    INFO_LOG_FMT(EXPANSIONINTERFACE, "SD Host Capacity Support: {}", hcs);
    m_idle = false;
    response.push_back(0);  // R1 - not idle
    break;
  }
  case AppCommand::AppCmd:
    // According to the spec, any unknown app command should be treated as a regular command, but
    // also things should not use this functionality.  It also specifically mentions that sending
    // CMD55 multiple times is the same as sending it only once: the next command that isn't 55 is
    // treated as an app command.
    state = State::ReadyForAppCommand;
    response.push_back(0);  // R1 - not idle
    break;
  default:
    // Don't know it
    WARN_LOG_FMT(EXPANSIONINTERFACE, "Unimplemented SD app command {:02x} {:08x}",
                 static_cast<u8>(app_command), argument);
    response.push_back(static_cast<u8>(R1::IllegalCommand));
  }
}

u8 CEXISD::ReadByte()
{
  if (state == State::SingleBlockRead || state == State::MultipleBlockRead)
  {
    return ReadForBlockRead();
  }
  else if (state == State::SingleBlockWrite || state == State::MultipleBlockWrite)
  {
    return ReadForBlockWrite();
  }
  else
  {
    if (response.empty())
    {
      // Note that SD cards are detected by trying to read a device ID, and getting 0xffffffff back;
      // this behavior is required for correct handling.
      return 0xff;
    }
    else
    {
      u8 result = response.front();
      response.pop_front();
      return result;
    }
  }
}

u8 CEXISD::ReadForBlockRead()
{
  switch (block_state)
  {
  case BlockState::Response:
  {
    // Would return address error or parameter error here
    block_state = BlockState::Token;
    return 0;
  }
  case BlockState::Token:
    // Perform the actual read at this point, as every block needs a start block token or an error
    // token Oddly, the error token is slightly redundant, since there's an out of bounds response
    // in R1, which can happen above, but there's also one here.
    if (!m_card.Seek(address, File::SeekOrigin::Begin))
    {
      ERROR_LOG_FMT(EXPANSIONINTERFACE, "fseeko failed WTF");
      state = State::ReadyForCommand;
      block_state = BlockState::Nothing;
      return DATA_ERROR_OUT_OF_RANGE;
    }
    else if (!m_card.ReadBytes(block_buffer.data(), BLOCK_SIZE))
    {
      ERROR_LOG_FMT(EXPANSIONINTERFACE, "SD read failed at {:#x} - error: {}, eof: {}", address,
                    ferror(m_card.GetHandle()), feof(m_card.GetHandle()));
      state = State::ReadyForCommand;
      block_state = BlockState::Nothing;
      return DATA_ERROR_ERROR;
    }
    else
    {
      INFO_LOG_FMT(EXPANSIONINTERFACE, "SD read succeeded at {:#x}", address);
      block_position = 0;
      block_state = BlockState::Block;
      block_crc = HashCrc16(block_buffer);
      return START_BLOCK;
    }
  case BlockState::Block:
  {
    u8 result = block_buffer[block_position++];
    if (block_position >= BLOCK_SIZE)
    {
      block_state = BlockState::Checksum1;
    }
    return result;
  }
  case BlockState::Checksum1:
    block_state = BlockState::Checksum2;
    return static_cast<u8>(block_crc >> 8);
  case BlockState::Checksum2:
  {
    u8 result = static_cast<u8>(block_crc);
    if (state == State::MultipleBlockRead)
    {
      address += BLOCK_SIZE;
      block_state = BlockState::Token;
    }
    else
    {
      address = 0;
      block_position = 0;
      block_state = BlockState::Nothing;
      state = State::ReadyForCommand;
    }
    return result;
  }
  default:
    ERROR_LOG_FMT(EXPANSIONINTERFACE, "Unexpected block_state {} for reading", u32(block_state));
    return 0xff;
  }
}

void CEXISD::WriteForBlockRead(u8 byte)
{
  // The only thing a host sends while it reads blocks is the command that ends the read. Wait
  // for all six bytes of it: the last one is a CRC, or 0xff from a host that does not send one.
  constexpr u8 STOP_TRANSMISSION = 0x40 | static_cast<u8>(Command::StopTransmission);
  if (command_position == 0)
  {
    if (byte == STOP_TRANSMISSION)
      command_position = 1;
    else if (byte != 0xff)
      WARN_LOG_FMT(EXPANSIONINTERFACE, "Data written during block read: {:02x}", byte);
    return;
  }
  if (++command_position < command_buffer.size())
    return;

  // A card stops sending within a byte, wherever in the block it was: libogc reads the next
  // block's first bytes as filler before it sends this command.
  command_position = 0;
  address = 0;
  block_position = 0;
  block_state = BlockState::Nothing;
  state = State::ReadyForCommand;
  response.clear();
  // A byte the host throws away, then R1. Every byte after that is 0xff: not busy.
  response.push_back(0);
  response.push_back(0);
}

u8 CEXISD::ReadForBlockWrite()
{
  switch (block_state)
  {
  case BlockState::Response:
    block_state = BlockState::Token;
    // Would return address error or parameter error here
    return 0;
  case BlockState::Token:
  case BlockState::Block:
  case BlockState::Checksum1:
  case BlockState::Checksum2:
    return 0xff;
  case BlockState::ChecksumWritten:
  {
    u16 actual_crc = HashCrc16(block_buffer);
    u8 result;
    if (actual_crc != block_crc)
    {
      ERROR_LOG_FMT(EXPANSIONINTERFACE, "Bad CRC: was {:04x}, should be {:04x}", actual_crc,
                    block_crc);
      result = DATA_RESPONSE_BAD_CRC;
    }
    else if (!m_card.Seek(address, File::SeekOrigin::Begin))
    {
      ERROR_LOG_FMT(EXPANSIONINTERFACE, "fseeko failed WTF");
      result = DATA_RESPONSE_WRITE_ERROR;
    }
    else if (!m_card.WriteBytes(block_buffer.data(), BLOCK_SIZE))
    {
      ERROR_LOG_FMT(EXPANSIONINTERFACE, "SD write failed at {:#x} - error: {}, eof: {}", address,
                    ferror(m_card.GetHandle()), feof(m_card.GetHandle()));
      result = DATA_RESPONSE_WRITE_ERROR;
    }
    else
    {
      INFO_LOG_FMT(EXPANSIONINTERFACE, "SD write succeeded at {:#x}", address);
      result = DATA_RESPONSE_ACCEPTED;
    }

    if (state == State::SingleBlockWrite)
    {
      state = State::ReadyForCommand;
      block_state = BlockState::Nothing;
      address = 0;
      block_position = 0;
    }
    else
    {
      block_state = BlockState::Token;
      address += BLOCK_SIZE;
      block_position = 0;
    }

    return result;
  }
  default:
    ERROR_LOG_FMT(EXPANSIONINTERFACE, "Unexpected block_state {} for writing", u32(block_state));
    return 0xff;
  }
}

void CEXISD::WriteForBlockWrite(u8 byte)
{
  switch (block_state)
  {
  case BlockState::Response:
    // Do nothing
    break;
  case BlockState::Token:
    if (byte == START_MULTI_BLOCK)
    {
      block_position = 0;
      block_crc = 0;
      block_state = BlockState::Block;
    }
    else if (byte == END_BLOCK)
    {
      state = State::ReadyForCommand;
      block_state = BlockState::Nothing;
    }
    else if (byte != 0xff)
    {
      ERROR_LOG_FMT(EXPANSIONINTERFACE, "Unexpected token for block write {:02x}", byte);
    }
    break;
  case BlockState::Block:
    block_buffer[block_position++] = byte;
    if (block_position >= BLOCK_SIZE)
    {
      block_state = BlockState::Checksum1;
    }
    break;
  case BlockState::Checksum1:
    block_crc |= byte << 8;
    block_state = BlockState::Checksum2;
    break;
  case BlockState::Checksum2:
    block_crc |= byte;
    block_state = BlockState::ChecksumWritten;
    break;
  case BlockState::ChecksumWritten:
    // Do nothing
    break;
  default:
    ERROR_LOG_FMT(EXPANSIONINTERFACE, "Unexpected block_state {} for writing", u32(block_state));
  }
}
}  // namespace ExpansionInterface
