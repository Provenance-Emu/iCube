#include "DiscIO/HttpBlobReader.h"

#include <algorithm>
#include <cctype>

#include "Common/Logging/Log.h"
#include "Common/StringUtil.h"

namespace DiscIO
{
namespace
{
static inline std::string LowerCopy(std::string s)
{
  Common::ToLower(&s);
  return s;
}

static inline bool IsHttpUrl(const std::string& url)
{
  const auto lower = LowerCopy(url);
  return lower.rfind("http://", 0) == 0 || lower.rfind("https://", 0) == 0 ||
         lower.rfind("webdav://", 0) == 0 || lower.rfind("webdavs://", 0) == 0;
}

static std::string ToHttpUrl(const std::string& url)
{
  // Map webdav(s) schemes to http(s) for libcurl
  const auto lower = LowerCopy(url);
  if (lower.rfind("webdavs://", 0) == 0)
    return std::string("https://") + url.substr(strlen("webdavs://"));
  if (lower.rfind("webdav://", 0) == 0)
    return std::string("http://") + url.substr(strlen("webdav://"));
  return url;
}
}

std::unique_ptr<HttpBlobReader> HttpBlobReader::Create(const std::string& url)
{
  if (!IsHttpUrl(url))
    return nullptr;
  return std::unique_ptr<HttpBlobReader>(new HttpBlobReader(ToHttpUrl(url)));
}

HttpBlobReader::HttpBlobReader(std::string url) : m_url(std::move(url)) {}

std::unique_ptr<BlobReader> HttpBlobReader::CopyReader() const
{
  return Create(m_url);
}

u64 HttpBlobReader::GetRawSize() const
{
  const_cast<HttpBlobReader*>(this)->EnsureSize();
  return m_size.value_or(0);
}

u64 HttpBlobReader::GetDataSize() const
{
  return GetRawSize();
}

bool HttpBlobReader::EnsureSize()
{
  if (m_size.has_value())
    return true;

  Common::HttpRequest req;
  if (!req.IsValid())
    return false;

  // Use Range: bytes=0-0 to infer Content-Range: bytes 0-0/total
  Common::HttpRequest::Headers headers;
  headers.emplace("Range", std::string("bytes=0-0"));
  const auto resp = req.Get(m_url, headers, Common::HttpRequest::AllowedReturnCodes::All);
  const auto code = req.GetLastResponseCode();
  if (code != 200 && code != 206)
    return false;

  // Try Content-Range first
  const std::string crange = req.GetHeaderValue("Content-Range");
  if (!crange.empty())
  {
    // Format: bytes start-end/total
    const auto slash = crange.find('/');
    if (slash != std::string::npos && slash + 1 < crange.size())
    {
      const std::string total_str = crange.substr(slash + 1);
      u64 total = 0;
      if (TryParse(total_str, &total))
      {
        m_size = total;
        return true;
      }
    }
  }

  // Fallback to Content-Length on 200
  const std::string clen = req.GetHeaderValue("Content-Length");
  if (!clen.empty())
  {
    u64 len = 0;
    if (TryParse(clen, &len))
    {
      m_size = len;
      return true;
    }
  }

  // As a last resort, use the body size of this small response
  if (resp)
  {
    m_size = static_cast<u64>(resp->size());
    return true;
  }
  return false;
}

bool HttpBlobReader::FetchRange(u64 offset, u64 size, std::vector<u8>* out)
{
  Common::HttpRequest req;
  if (!req.IsValid())
    return false;

  const u64 end = offset + (size ? (size - 1) : 0);
  Common::HttpRequest::Headers headers;
  headers.emplace("Range", fmt::format("bytes={}-{}", offset, end));

  const auto resp = req.Get(m_url, headers, Common::HttpRequest::AllowedReturnCodes::All);
  const auto code = req.GetLastResponseCode();
  if (code != 206 && code != 200)
    return false;
  if (!resp)
    return false;

  // If 200 returned, server ignored range and sent full body; honor but copy only requested slice
  const auto& body = *resp;
  if (code == 200)
  {
    if (body.size() < size)
      return false;
    out->assign(body.begin(), body.begin() + size);
    return true;
  }

  out->assign(body.begin(), body.end());
  return out->size() == size;
}

bool HttpBlobReader::Read(u64 offset, u64 size, u8* out_ptr)
{
  if (size == 0)
    return true;
  if (!EnsureSize())
    return false;
  if (offset >= *m_size)
    return false;
  if (offset + size > *m_size)
    size = *m_size - offset;

  std::vector<u8> buffer;
  if (!FetchRange(offset, size, &buffer))
    return false;

  std::copy(buffer.begin(), buffer.end(), out_ptr);
  return true;
}

}  // namespace DiscIO
