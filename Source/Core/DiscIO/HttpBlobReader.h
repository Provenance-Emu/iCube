#pragma once

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "Common/CommonTypes.h"
#include "Common/HttpRequest.h"
#include "DiscIO/Blob.h"

namespace DiscIO
{
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

private:
  explicit HttpBlobReader(std::string url);

  bool EnsureSize();
  bool FetchRange(u64 offset, u64 size, std::vector<u8>* out);

  std::string m_url;
  mutable std::optional<u64> m_size;
};
}  // namespace DiscIO
