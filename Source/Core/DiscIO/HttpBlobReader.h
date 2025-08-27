#pragma once

#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <unordered_map>

#include "Common/CommonTypes.h"
#include "Common/HttpRequest.h"
#include "DiscIO/Blob.h"

namespace DiscIO
{
// Cache entry for HTTP blob data
struct HttpCacheEntry
{
  std::vector<u8> data;
  u64 offset;
  u64 size;
  u64 last_access_time; // For LRU eviction
};

class HttpBlobReader final : public BlobReader
{
public:
  static std::unique_ptr<HttpBlobReader> Create(const std::string& url);

  BlobType GetBlobType() const override { return BlobType::PLAIN; }
  std::unique_ptr<BlobReader> CopyReader() const override;

  u64 GetRawSize() const override;
  u64 GetDataSize() const override;
  DataSizeType GetDataSizeType() const override { return DataSizeType::Accurate; }

  u64 GetBlockSize() const override { return 0; }
  bool HasFastRandomAccessInBlock() const override { return true; }
  std::string GetCompressionMethod() const override { return {}; }
  std::optional<int> GetCompressionLevel() const override { return std::nullopt; }

  bool Read(u64 offset, u64 size, u8* out_ptr) override;

  // Getter for URL (needed by HttpCISOReader)
  const std::string& GetUrl() const { return m_url; }

private:
  explicit HttpBlobReader(std::string url);

  bool EnsureSize();
  bool FetchRange(u64 offset, u64 size, std::vector<u8>* out);

  // Cache management
  bool ReadFromCache(u64 offset, u64 size, u8* out_ptr);
  void AddToCache(u64 offset, const std::vector<u8>& data);
  void EvictOldCacheEntries();
  u64 GetCurrentTimeMs() const;

  std::string m_url;
  mutable u64 m_size = 0;
  mutable bool m_size_known = false;

  // Cache settings
  static constexpr u64 CACHE_BLOCK_SIZE = 1024 * 1024; // 1MB cache blocks
  static constexpr size_t MAX_CACHE_ENTRIES = 64; // Max 64MB cache
  static constexpr u64 CACHE_ENTRY_LIFETIME_MS = 30000; // 30 seconds

  // Cache storage
  mutable std::unordered_map<u64, HttpCacheEntry> m_cache; // Key: block start offset
  mutable u64 m_cache_access_counter = 0;

  // Cache statistics
  mutable u64 m_cache_hits = 0;
  mutable u64 m_cache_misses = 0;

  // Sequential access tracking for smart prefetching
  mutable u64 m_last_read_offset = 0;
  mutable u64 m_sequential_reads = 0;
};

// HTTP-backed CISO reader for compressed CISO files over HTTP
class HttpCISOReader : public BlobReader
{
public:
  static std::unique_ptr<HttpCISOReader> Create(const std::string& url);

  BlobType GetBlobType() const override { return BlobType::CISO; }
  std::unique_ptr<BlobReader> CopyReader() const override;

  u64 GetRawSize() const override;
  u64 GetDataSize() const override;
  DataSizeType GetDataSizeType() const override { return DataSizeType::Accurate; }

  u64 GetBlockSize() const override;
  bool HasFastRandomAccessInBlock() const override { return true; }
  std::string GetCompressionMethod() const override { return {}; }
  std::optional<int> GetCompressionLevel() const override { return std::nullopt; }

  bool Read(u64 offset, u64 size, u8* out_ptr) override;

private:
  explicit HttpCISOReader(std::unique_ptr<HttpBlobReader> http_reader);
  bool ReadHeader();

  std::unique_ptr<HttpBlobReader> m_http_reader;
  u32 m_block_size = 0;
  u16 m_ciso_map[32764]; // CISO_MAP_SIZE from CISOBlob.h (0x8000 - 4 - 4 = 32764)
  u64 m_size = 0;
  bool m_header_read = false;
};

// HTTP-backed RVZ reader for RVZ files over HTTP
class HttpRVZReader : public BlobReader
{
public:
  static std::unique_ptr<HttpRVZReader> Create(const std::string& url);

  BlobType GetBlobType() const override { return BlobType::RVZ; }
  std::unique_ptr<BlobReader> CopyReader() const override;

  u64 GetRawSize() const override;
  u64 GetDataSize() const override;
  DataSizeType GetDataSizeType() const override { return DataSizeType::Accurate; }

  u64 GetBlockSize() const override;
  bool HasFastRandomAccessInBlock() const override { return false; }
  std::string GetCompressionMethod() const override;
  std::optional<int> GetCompressionLevel() const override;

  bool Read(u64 offset, u64 size, u8* out_ptr) override;

private:
  // RVZ structures (simplified from WIABlob.h)
  struct RVZHeader1
  {
    u32 magic;
    u32 version;
    u32 version_compatible;
    u32 header_2_size;
    u8 header_2_hash[20]; // SHA1 hash
    u64 iso_file_size;
    u64 wia_file_size;
    u8 header_1_hash[20]; // SHA1 hash
  };

  struct RVZHeader2
  {
    u32 disc_type;
    u32 compression_type;
    s32 compression_level;
    u32 chunk_size;
    u8 disc_header[0x80];
    u32 number_of_partition_entries;
    u32 partition_entry_size;
    u64 partition_entries_offset;
    u8 partition_entries_hash[20];
    u32 number_of_raw_data_entries;
    u64 raw_data_entries_offset;
    u32 raw_data_entries_size;
    u32 number_of_group_entries;
    u64 group_entries_offset;
    u32 group_entries_size;
    u8 compressor_data_size;
    u8 compressor_data[7];
  };

  struct RVZGroupEntry
  {
    u32 data_offset;  // >> 2
    u32 data_size;
    u32 rvz_packed_size;
  };

  struct RawDataEntry
  {
    u64 data_offset;
    u64 data_size;
    u32 group_index;
    u32 number_of_groups;
  };

  explicit HttpRVZReader(std::unique_ptr<HttpBlobReader> http_reader);
  bool ReadHeader();
  bool ReadFromGroups(u64* offset, u64* size, u8** out_ptr, u64 chunk_size, u32 sector_size,
                      u64 data_offset, u64 data_size, u32 group_index, u32 number_of_groups);

  std::unique_ptr<HttpBlobReader> m_http_reader;
  bool m_header_read = false;

  // RVZ headers and data
  RVZHeader1 m_header_1;
  RVZHeader2 m_header_2;
  std::vector<RVZGroupEntry> m_group_entries;
  std::vector<RawDataEntry> m_raw_data_entries;

  // Compression info
  u32 m_compression_type = 0;
  u64 m_iso_file_size = 0;
  u64 m_chunk_size = 0;

  // Simple block cache for decompressed data
  mutable std::unordered_map<u64, std::vector<u8>> m_decompressed_cache;
  static constexpr size_t MAX_CACHED_CHUNKS = 8; // Cache up to 8 decompressed chunks
};

// HTTP-backed GCZ reader for compressed GCZ files over HTTP
class HttpGCZReader : public BlobReader
{
public:
  static std::unique_ptr<HttpGCZReader> Create(const std::string& url);

  BlobType GetBlobType() const override { return BlobType::GCZ; }
  std::unique_ptr<BlobReader> CopyReader() const override;

  u64 GetRawSize() const override;
  u64 GetDataSize() const override;
  DataSizeType GetDataSizeType() const override { return DataSizeType::Accurate; }

  u64 GetBlockSize() const override;
  bool HasFastRandomAccessInBlock() const override { return true; }
  std::string GetCompressionMethod() const override { return "Deflate"; }
  std::optional<int> GetCompressionLevel() const override { return {}; }

  bool Read(u64 offset, u64 size, u8* out_ptr) override;

private:
  explicit HttpGCZReader(std::unique_ptr<HttpBlobReader> http_reader);
  bool ReadHeader();

  std::unique_ptr<HttpBlobReader> m_http_reader;
  u64 m_data_size = 0;
  u32 m_block_size = 0;
  std::vector<u64> m_block_pointers;  // Changed from u32 to u64
  bool m_header_read = false;

  // Helper methods for GCZ decompression
  bool ReadCompressedBlock(u64 block_num, std::vector<u8>* out);
  bool DecompressBlock(const std::vector<u8>& compressed_data, std::vector<u8>* out);
};

// HTTP-backed WBFS reader for WBFS files over HTTP
class HttpWBFSReader : public BlobReader
{
public:
  static std::unique_ptr<HttpWBFSReader> Create(const std::string& url);

  BlobType GetBlobType() const override { return BlobType::WBFS; }
  std::unique_ptr<BlobReader> CopyReader() const override;

  u64 GetRawSize() const override;
  u64 GetDataSize() const override;
  DataSizeType GetDataSizeType() const override { return DataSizeType::Accurate; }

  u64 GetBlockSize() const override;
  bool HasFastRandomAccessInBlock() const override { return true; }
  std::string GetCompressionMethod() const override { return {}; }
  std::optional<int> GetCompressionLevel() const override { return {}; }

  bool Read(u64 offset, u64 size, u8* out_ptr) override;

private:
  explicit HttpWBFSReader(std::unique_ptr<HttpBlobReader> http_reader);
  bool ReadHeader();

  std::unique_ptr<HttpBlobReader> m_http_reader;
  u64 m_data_size = 0;
  u32 m_sector_size = 0;
  bool m_header_read = false;
};

// HTTP-backed TGC reader for TGC files over HTTP
class HttpTGCReader : public BlobReader
{
public:
  static std::unique_ptr<HttpTGCReader> Create(const std::string& url);

  BlobType GetBlobType() const override { return BlobType::TGC; }
  std::unique_ptr<BlobReader> CopyReader() const override;

  u64 GetRawSize() const override;
  u64 GetDataSize() const override;
  DataSizeType GetDataSizeType() const override { return DataSizeType::Accurate; }

  u64 GetBlockSize() const override { return 0; }
  bool HasFastRandomAccessInBlock() const override { return true; }
  std::string GetCompressionMethod() const override { return {}; }
  std::optional<int> GetCompressionLevel() const override { return {}; }

  bool Read(u64 offset, u64 size, u8* out_ptr) override;

private:
  explicit HttpTGCReader(std::unique_ptr<HttpBlobReader> http_reader);
  bool ReadHeader();

  std::unique_ptr<HttpBlobReader> m_http_reader;
  u64 m_data_size = 0;
  u32 m_header_size = 0;
  bool m_header_read = false;
};

class HttpWIAReader : public BlobReader
{
public:
  static std::unique_ptr<HttpWIAReader> Create(const std::string& url);

  BlobType GetBlobType() const override { return BlobType::WIA; }
  std::unique_ptr<BlobReader> CopyReader() const override;

  u64 GetRawSize() const override;
  u64 GetDataSize() const override;
  DataSizeType GetDataSizeType() const override { return DataSizeType::Accurate; }

  u64 GetBlockSize() const override;
  bool HasFastRandomAccessInBlock() const override { return false; }
  std::string GetCompressionMethod() const override;
  std::optional<int> GetCompressionLevel() const override;

  bool Read(u64 offset, u64 size, u8* out_ptr) override;

private:
  // WIA structures based on the format specification
  struct WIAFileHeader
  {
    char magic[4];           // "WIA\x1"
    u32 version;
    u32 version_compatible;
    u32 disc_size;
    u8 disc_hash[20];        // SHA-1 hash
    u64 iso_file_size;
    u64 wia_file_size;
    u8 file_head_hash[20];   // SHA-1 hash
  };

  struct WIADiscHeader
  {
    u32 disc_type;           // 0=unknown, 1=GameCube, 2=Wii
    u32 compression;         // 0=NONE, 1=PURGE, 2=BZIP2, 3=LZMA, 4=LZMA2
    u32 compr_level;
    u32 chunk_size;
    u8 dhead[0x80];          // First 0x80 bytes of disc
    u32 n_part;
    u32 part_t_size;
    u64 part_off;
    u8 part_hash[20];
    u32 n_raw_data;
    u64 raw_data_off;
    u32 raw_data_size;
    u32 n_groups;
    u64 group_off;
    u32 group_size;
    u8 compr_data_len;
    u8 compr_data[7];
  };

  struct WIARawDataEntry
  {
    u64 raw_data_off;
    u64 raw_data_size;
    u32 group_index;
    u32 n_groups;
  };

  struct WIAGroupEntry
  {
    u32 data_off4;           // Offset divided by 4
    u32 data_size;
  };

  explicit HttpWIAReader(std::unique_ptr<HttpBlobReader> http_reader);
  bool ReadHeaders();
  bool ReadRawDataEntries();
  bool ReadGroupEntries();
  bool ReadFromGroups(u64 offset, u64 size, u8* out_ptr);

  std::unique_ptr<HttpBlobReader> m_http_reader;
  bool m_headers_read = false;

  // WIA headers and data
  WIAFileHeader m_file_header;
  WIADiscHeader m_disc_header;
  std::vector<WIARawDataEntry> m_raw_data_entries;
  std::vector<WIAGroupEntry> m_group_entries;

  // Compression info
  u32 m_compression_type = 0;
  u64 m_iso_file_size = 0;
  u64 m_chunk_size = 0;

  // Simple block cache for decompressed data
  mutable std::unordered_map<u64, std::vector<u8>> m_decompressed_cache;
  static constexpr size_t MAX_CACHED_CHUNKS = 8; // Cache up to 8 decompressed chunks
};

}  // namespace DiscIO
