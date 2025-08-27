// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "DiscIO/Blob.h"

#include <algorithm>
#include <cstddef>
#include <cstdlib>
#include <limits>
#include <memory>
#include <string>
#include <utility>

#include "Common/CommonTypes.h"
#include "Common/IOFile.h"
#include "Common/MsgHandler.h"
#include "Common/StringUtil.h"

#include "DiscIO/CISOBlob.h"
#include "DiscIO/CompressedBlob.h"
#include "DiscIO/DirectoryBlob.h"
#include "DiscIO/FileBlob.h"
#include "DiscIO/HttpBlobReader.h"
#include "DiscIO/NFSBlob.h"
#include "DiscIO/SplitFileBlob.h"
#include "DiscIO/TGCBlob.h"
#include "DiscIO/WIABlob.h"
#include "DiscIO/WbfsBlob.h"

// Helper function to check for cached files
static std::string CheckForCachedFile(const std::string& http_url)
{
  // Check if this HTTP URL has a cached version available
  // We need to integrate with the Swift WebDAVSource cache system

  INFO_LOG_FMT(DISCIO, "CheckForCachedFile: checking cache for URL: {}", http_url);

  // For iOS/tvOS, we can check the standard cache directory structure
  // Cache files are stored in ~/Library/Caches/RemoteCache/{sourceId}/

#ifdef __APPLE__
  // Only handle WebDAV URLs for now
  std::string lower_url = http_url;
  Common::ToLower(&lower_url);
  if (lower_url.find("http://") != 0 && lower_url.find("https://") != 0)
  {
    return "";
  }

  // Extract filename from URL path
  size_t filename_start = http_url.find_last_of('/');
  if (filename_start == std::string::npos)
    return "";

  std::string filename = http_url.substr(filename_start + 1);

  // URL decode the filename
  std::string decoded_filename;
  for (size_t i = 0; i < filename.length(); ++i)
  {
    if (filename[i] == '%' && i + 2 < filename.length())
    {
      // Simple URL decoding for common cases
      if (filename.substr(i, 3) == "%20")
      {
        decoded_filename += ' ';
        i += 2;
      }
      else if (filename.substr(i, 3) == "%21")
      {
        decoded_filename += '!';
        i += 2;
      }
      else
      {
        decoded_filename += filename[i];
      }
    }
    else
    {
      decoded_filename += filename[i];
    }
  }

    // Parse URL to extract host and port for consistent ID generation (matches Swift logic)
  size_t protocol_end = lower_url.find("://");
  if (protocol_end == std::string::npos)
    return "";

  size_t host_start = protocol_end + 3;
  size_t path_start = lower_url.find('/', host_start);
  if (path_start == std::string::npos)
    path_start = lower_url.length();

  std::string host_port_part = lower_url.substr(host_start, path_start - host_start);

  // Extract host and port
  std::string host;
  int port = 80; // Default port
  size_t port_pos = host_port_part.find(':');
  if (port_pos != std::string::npos)
  {
    host = host_port_part.substr(0, port_pos);
    port = std::stoi(host_port_part.substr(port_pos + 1));
  }
  else
  {
    host = host_port_part;
    // Determine default port based on scheme
    if (lower_url.find("https://") == 0)
      port = 443;
  }

  // Generate consistent ID (matches Swift logic exactly)
  std::string host_with_port = host + ":" + std::to_string(port);
  std::string source_id = host_with_port;
  std::replace(source_id.begin(), source_id.end(), '.', '_');
  std::replace(source_id.begin(), source_id.end(), ':', '_');

  // Check for cached file using consistent source ID
  // ~/Library/Caches/RemoteCache/{sourceId}/{filename}
  std::string home_dir = getenv("HOME") ? getenv("HOME") : "";
  if (home_dir.empty())
    return "";

  std::string cache_path = home_dir + "/Library/Caches/RemoteCache/" + source_id + "/" + decoded_filename;

  // Check if the cached file exists
  if (File::Exists(cache_path))
  {
    INFO_LOG_FMT(DISCIO, "CheckForCachedFile: found cached file at: {}", cache_path);
    return cache_path;
  }

  INFO_LOG_FMT(DISCIO, "CheckForCachedFile: no cached file found for: {} (source_id: {})", decoded_filename, source_id);
#endif

  return ""; // No cached file found
}

namespace DiscIO
{
std::string GetName(BlobType blob_type, bool translate)
{
  const auto translate_str = [translate](const std::string& str) {
    return translate ? Common::GetStringT(str.c_str()) : str;
  };

  switch (blob_type)
  {
  case BlobType::PLAIN:
    return "ISO";
  case BlobType::DIRECTORY:
    return translate_str("Directory");
  case BlobType::GCZ:
    return "GCZ";
  case BlobType::CISO:
    return "CISO";
  case BlobType::WBFS:
    return "WBFS";
  case BlobType::TGC:
    return "TGC";
  case BlobType::WIA:
    return "WIA";
  case BlobType::RVZ:
    return "RVZ";
  case BlobType::MOD_DESCRIPTOR:
    return translate_str("Mod");
  case BlobType::NFS:
    return "NFS";
  case BlobType::SPLIT_PLAIN:
    return translate_str("Multi-part ISO");
  default:
    return "";
  }
}

void SectorReader::SetSectorSize(int blocksize)
{
  m_block_size = std::max(blocksize, 0);
  for (auto& cache_entry : m_cache)
  {
    cache_entry.Reset();
    cache_entry.data.resize(m_chunk_blocks * m_block_size);
  }
}

void SectorReader::SetChunkSize(int block_cnt)
{
  m_chunk_blocks = std::max(block_cnt, 1);
  // Clear cache and resize the data arrays
  SetSectorSize(m_block_size);
}

SectorReader::~SectorReader()
{
}

const SectorReader::Cache* SectorReader::FindCacheLine(u64 block_num)
{
  auto itr =
      std::ranges::find_if(m_cache, [&](const Cache& entry) { return entry.Contains(block_num); });
  if (itr == m_cache.end())
    return nullptr;

  itr->MarkUsed();
  return &*itr;
}

SectorReader::Cache* SectorReader::GetEmptyCacheLine()
{
  Cache* oldest = &m_cache[0];
  // Find the Least Recently Used cache line to replace.
  std::for_each(m_cache.begin() + 1, m_cache.end(), [&](Cache& line) {
    if (line.IsLessRecentlyUsedThan(*oldest))
    {
      oldest->ShiftLRU();
      oldest = &line;
      return;
    }
    line.ShiftLRU();
  });
  oldest->Reset();
  return oldest;
}

const SectorReader::Cache* SectorReader::GetCacheLine(u64 block_num)
{
  if (auto entry = FindCacheLine(block_num))
    return entry;

  // Cache miss. Fault in the missing entry.
  Cache* cache = GetEmptyCacheLine();
  // We only read aligned chunks, this avoids duplicate overlapping entries.
  u64 chunk_idx = block_num / m_chunk_blocks;
  u32 blocks_read = ReadChunk(cache->data.data(), chunk_idx);
  if (!blocks_read)
    return nullptr;
  cache->Fill(chunk_idx * m_chunk_blocks, blocks_read);

  // Secondary check for out-of-bounds read.
  // If we got less than m_chunk_blocks, we may still have missed.
  // We do this after the cache fill since the cache line itself is
  // fine, the problem is being asked to read past the end of the disk.
  return cache->Contains(block_num) ? cache : nullptr;
}

bool SectorReader::Read(u64 offset, u64 size, u8* out_ptr)
{
  if (offset + size > GetDataSize())
    return false;

  u64 remain = size;
  u64 block = 0;
  u32 position_in_block = static_cast<u32>(offset % m_block_size);

  while (remain > 0)
  {
    block = offset / m_block_size;

    const Cache* cache = GetCacheLine(block);
    if (!cache)
      return false;

    // Cache entries are aligned chunks, we may not want to read from the start
    u32 read_offset = static_cast<u32>(block - cache->block_idx) * m_block_size + position_in_block;
    u32 can_read = m_block_size * cache->num_blocks - read_offset;
    u32 was_read = static_cast<u32>(std::min<u64>(can_read, remain));

    std::copy_n(cache->data.begin() + read_offset, was_read, out_ptr);

    offset += was_read;
    out_ptr += was_read;
    remain -= was_read;
    position_in_block = 0;
  }
  return true;
}

// Crap default implementation if not overridden.
bool SectorReader::ReadMultipleAlignedBlocks(u64 block_num, u64 cnt_blocks, u8* out_ptr)
{
  for (u64 i = 0; i < cnt_blocks; ++i)
  {
    if (!GetBlock(block_num + i, out_ptr))
      return false;
    out_ptr += m_block_size;
  }
  return true;
}

u32 SectorReader::ReadChunk(u8* buffer, u64 chunk_num)
{
  u64 block_num = chunk_num * m_chunk_blocks;
  u32 cnt_blocks = m_chunk_blocks;

  // If we are reading the end of a disk, there may not be enough blocks to
  // read a whole chunk. We need to clamp down in that case.
  u64 end_block = (GetDataSize() + m_block_size - 1) / m_block_size;
  if (end_block)
    cnt_blocks = static_cast<u32>(std::min<u64>(m_chunk_blocks, end_block - block_num));

  if (ReadMultipleAlignedBlocks(block_num, cnt_blocks, buffer))
  {
    if (cnt_blocks < m_chunk_blocks)
    {
      std::fill(buffer + cnt_blocks * m_block_size, buffer + m_chunk_blocks * m_block_size, 0u);
    }
    return cnt_blocks;
  }

  // end_block may be zero on real disks if we fail to get the media size.
  // We have to fallback to probing the disk instead.
  if (!end_block)
  {
    for (u32 i = 0; i < cnt_blocks; ++i)
    {
      if (!GetBlock(block_num + i, buffer))
      {
        std::fill_n(buffer, (cnt_blocks - i) * m_block_size, 0u);
        return i;
      }
      buffer += m_block_size;
    }
    return cnt_blocks;
  }
  return 0;
}

std::unique_ptr<BlobReader> CreateBlobReader(const std::string& filename)
{
  INFO_LOG_FMT(DISCIO, "CreateBlobReader called with filename: {}", filename);

  // Remote URL support: if path looks like http(s)/webdav(s), use HttpBlobReader
  std::string lower = filename;
  Common::ToLower(&lower);
  if (lower.rfind("http://", 0) == 0 || lower.rfind("https://", 0) == 0 ||
      lower.rfind("webdav://", 0) == 0 || lower.rfind("webdavs://", 0) == 0)
  {
    INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected HTTP URL, checking for cached files");

    // Check if we have a cached version of this file
    std::string cachedPath = CheckForCachedFile(filename);
    if (!cachedPath.empty())
    {
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: found cached file at {}, using local reader", cachedPath);
      return CreateBlobReader(cachedPath); // Recursive call with local path
    }

    INFO_LOG_FMT(DISCIO, "CreateBlobReader: no cached file found, checking for compressed formats");

    // Create HttpBlobReader to read magic number
    auto http_reader = HttpBlobReader::Create(filename);
    if (!http_reader)
    {
      ERROR_LOG_FMT(DISCIO, "CreateBlobReader: HttpBlobReader::Create returned nullptr for {}", filename);
      return nullptr;
    }

    // Read magic number from HTTP stream
    u32 magic = 0;
    if (!http_reader->Read(0, sizeof(magic), reinterpret_cast<u8*>(&magic)))
    {
      ERROR_LOG_FMT(DISCIO, "CreateBlobReader: failed to read magic number from HTTP URL {}", filename);
      // For uncompressed formats, return the HttpBlobReader as-is
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: assuming uncompressed format, returning HttpBlobReader");
      return http_reader;
    }

    INFO_LOG_FMT(DISCIO, "CreateBlobReader: read magic number 0x{:08x} from HTTP URL {}", magic, filename);

    // Check for compressed formats and create appropriate readers
    switch (magic)
    {
    case CISO_MAGIC:
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected CISO format in HTTP stream, creating HttpCISOReader");
      {
        auto reader = HttpCISOReader::Create(filename);
        if (!reader) {
          ERROR_LOG_FMT(DISCIO, "CreateBlobReader: HttpCISOReader::Create failed for {}", filename);
        }
        return reader;
      }

    case RVZ_MAGIC:
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected RVZ format in HTTP stream, creating HttpRVZReader");
      {
        auto reader = HttpRVZReader::Create(filename);
        if (!reader) {
          ERROR_LOG_FMT(DISCIO, "CreateBlobReader: HttpRVZReader::Create failed for {}", filename);
        }
        return reader;
      }

    case GCZ_MAGIC:
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected GCZ format in HTTP stream, creating HttpGCZReader");
      {
        auto reader = HttpGCZReader::Create(filename);
        if (!reader) {
          ERROR_LOG_FMT(DISCIO, "CreateBlobReader: HttpGCZReader::Create failed for {}", filename);
        }
        return reader;
      }

    case 0x01414957: // WIA_MAGIC
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected WIA format in HTTP stream, creating HttpWIAReader");
      {
        auto reader = HttpWIAReader::Create(filename);
        if (!reader) {
          ERROR_LOG_FMT(DISCIO, "CreateBlobReader: HttpWIAReader::Create failed for {}", filename);
        }
        return reader;
      }

    case 0xA2380FAE: // TGC_MAGIC
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected TGC format in HTTP stream, creating HttpTGCReader");
      {
        auto reader = HttpTGCReader::Create(filename);
        if (!reader) {
          ERROR_LOG_FMT(DISCIO, "CreateBlobReader: HttpTGCReader::Create failed for {}", filename);
        }
        return reader;
      }

    case 0x53464257: // WBFS_MAGIC
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected WBFS format in HTTP stream, creating HttpWBFSReader");
      {
        auto reader = HttpWBFSReader::Create(filename);
        if (!reader) {
          ERROR_LOG_FMT(DISCIO, "CreateBlobReader: HttpWBFSReader::Create failed for {}", filename);
        }
        return reader;
      }

    default:
      // Uncompressed format - return the HttpBlobReader
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: uncompressed format detected, returning HttpBlobReader");
      return http_reader;
    }
  }

  File::IOFile file(filename, "rb");
  u32 magic;
  if (!file.ReadArray(&magic, 1))
  {
    ERROR_LOG_FMT(DISCIO, "CreateBlobReader: failed to read magic number from {}", filename);
    return nullptr;
  }

  INFO_LOG_FMT(DISCIO, "CreateBlobReader: read magic number 0x{:08x} from {}", magic, filename);

  // Conveniently, every supported file format (except for plain disc images and
  // extracted discs) starts with a 4-byte magic number that identifies the format,
  // so we just need a simple switch statement to create the right blob type. If the
  // magic number doesn't match any known magic number and the directory structure
  // doesn't match the directory blob format, we assume it's a plain disc image. If
  // that assumption is wrong, the volume code that runs later will notice the error
  // because the blob won't provide the right data when reading the GC/Wii disc header.

  switch (magic)
  {
  case CISO_MAGIC:
    INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected CISO format for {}", filename);
    return CISOFileReader::Create(std::move(file));
  case GCZ_MAGIC:
    INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected GCZ format for {}", filename);
    return CompressedBlobReader::Create(std::move(file), filename);
  case TGC_MAGIC:
    INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected TGC format for {}", filename);
    return TGCFileReader::Create(std::move(file));
  case WBFS_MAGIC:
    INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected WBFS format for {}", filename);
    return WbfsFileReader::Create(std::move(file), filename);
  case WIA_MAGIC:
    INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected WIA format for {}", filename);
    return WIAFileReader::Create(std::move(file), filename);
  case RVZ_MAGIC:
    INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected RVZ format for {}", filename);
    return RVZFileReader::Create(std::move(file), filename);
  case NFS_MAGIC:
    INFO_LOG_FMT(DISCIO, "CreateBlobReader: detected NFS format for {}", filename);
    return NFSFileReader::Create(std::move(file), filename);
  default:
    INFO_LOG_FMT(DISCIO, "CreateBlobReader: no specific format detected, trying directory/split/plain for {}", filename);
    if (auto directory_blob = DirectoryBlobReader::Create(filename))
    {
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: created DirectoryBlobReader for {}", filename);
      return std::move(directory_blob);
    }
    if (auto split_blob = SplitPlainFileReader::Create(filename))
    {
      INFO_LOG_FMT(DISCIO, "CreateBlobReader: created SplitPlainFileReader for {}", filename);
      return std::move(split_blob);
    }

    INFO_LOG_FMT(DISCIO, "CreateBlobReader: creating PlainFileReader for {}", filename);
    return PlainFileReader::Create(std::move(file));
  }
}

}  // namespace DiscIO
