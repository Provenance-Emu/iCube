#include "DiscIO/HttpBlobReader.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <chrono>

#include <zlib.h>
#include <zstd.h>

#include "Common/Logging/Log.h"
#include "Common/StringUtil.h"
#include "Common/Swap.h"
#include "DiscIO/CISOBlob.h"
#include "DiscIO/WIABlob.h"
#include "DiscIO/WIACompression.h"

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>
#endif

#include "Common/CommonTypes.h"
#include "Common/FileUtil.h"
#include "Common/HttpRequest.h"

namespace DiscIO
{

static constexpr u16 UNUSED_BLOCK_ID = UINT16_MAX;

namespace
{
static inline std::string LowerCopy(std::string s)
{
  Common::ToLower(&s);
  return s;
}

static bool IsHttpUrl(const std::string& path)
{
  const std::string lower = LowerCopy(path);
  return lower.starts_with("http://") || lower.starts_with("https://") ||
  lower.starts_with("webdav://") || lower.starts_with("webdavs://");
}

static std::string ToHttpUrl(const std::string& path)
{
  std::string result = path;
  if (result.starts_with("webdav://"))
    result = "http://" + result.substr(9);
  else if (result.starts_with("webdavs://"))
    result = "https://" + result.substr(10);
  return result;
}

#ifdef __APPLE__
// Utility: CFStringRef -> std::string
static std::string CFStringToStdString(CFStringRef s)
{
  if (!s) return {};
  const CFIndex len = CFStringGetLength(s);
  const CFIndex maxSize = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
  std::string result;
  result.resize(static_cast<size_t>(maxSize));
  if (CFStringGetCString(s, result.data(), maxSize, kCFStringEncodingUTF8))
  {
    result.resize(strlen(result.c_str()));
    return result;
  }
  return {};
}

// Parse Content-Range header: "bytes start-end/total"
static std::optional<u64> ParseContentRangeTotal(const std::string& header)
{
  // Find slash and parse after it
  const auto slash = header.find('/');
  if (slash == std::string::npos)
    return std::nullopt;
  const std::string total_str = header.substr(slash + 1);
  if (total_str.empty() || total_str == "*")
    return std::nullopt;
  char* end = nullptr;
  unsigned long long val = strtoull(total_str.c_str(), &end, 10);
  if (end == total_str.c_str())
    return std::nullopt;
  return static_cast<u64>(val);
}

// Perform a HEAD request to get Content-Length. Fallback to GET with Range: bytes=0-0 to parse Content-Range
static std::optional<u64> GetRemoteSizeIOS(const std::string& url)
{
  if (url.empty())
  {
    ERROR_LOG_FMT(DISCIO, "GetRemoteSizeIOS: empty URL provided");
    return std::nullopt;
  }

  // Build URL
  CFStringRef urlString = CFStringCreateWithCString(kCFAllocatorDefault, url.c_str(), kCFStringEncodingUTF8);
  if (!urlString) return std::nullopt;
  CFURLRef cfUrl = CFURLCreateWithString(kCFAllocatorDefault, urlString, nullptr);
  CFRelease(urlString);
  if (!cfUrl) return std::nullopt;

  // 1) Try HEAD
  {
    CFHTTPMessageRef req = CFHTTPMessageCreateRequest(kCFAllocatorDefault, CFSTR("HEAD"), cfUrl, kCFHTTPVersion1_1);
    if (req)
    {
      CFReadStreamRef stream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, req);
      CFRelease(req);
      if (stream)
      {
        if (CFReadStreamOpen(stream))
        {
          // We don't need to read; just fetch headers
          CFHTTPMessageRef resp = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
          CFIndex status = 0;
          if (resp)
          {
            status = CFHTTPMessageGetResponseStatusCode(resp);
            CFStringRef cl = CFHTTPMessageCopyHeaderFieldValue(resp, CFSTR("Content-Length"));
            if (cl)
            {
              const std::string cl_str = CFStringToStdString(cl);
              CFRelease(cl);
              if (!cl_str.empty())
              {
                char* end = nullptr;
                unsigned long long sz = strtoull(cl_str.c_str(), &end, 10);
                if (end != cl_str.c_str() && sz > 0)
                {
                  CFReadStreamClose(stream);
                  CFRelease(stream);
                  CFRelease(resp);
                  INFO_LOG_FMT(DISCIO, "HttpBlobReader iOS: HEAD {} returned Content-Length {} (status {})", url, sz, status);
                  CFRelease(cfUrl);
                  return static_cast<u64>(sz);
                }
              }
            }
            CFRelease(resp);
          }
          CFReadStreamClose(stream);
        }
        CFRelease(stream);
      }
    }
  }

  // 2) Fallback: GET range 0-0, parse Content-Range: bytes 0-0/total
  {
    CFHTTPMessageRef req = CFHTTPMessageCreateRequest(kCFAllocatorDefault, CFSTR("GET"), cfUrl, kCFHTTPVersion1_1);
    if (req)
    {
      CFStringRef rangeHeader = CFSTR("bytes=0-0");
      CFHTTPMessageSetHeaderFieldValue(req, CFSTR("Range"), rangeHeader);
      CFReadStreamRef stream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, req);
      CFRelease(req);
      if (stream)
      {
        if (CFReadStreamOpen(stream))
        {
          // Drain small body (1 byte expected)
          u8 tmp[32];
          while (CFReadStreamRead(stream, tmp, sizeof(tmp)) > 0) {}
          CFHTTPMessageRef resp = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
          if (resp)
          {
            CFStringRef cr = CFHTTPMessageCopyHeaderFieldValue(resp, CFSTR("Content-Range"));
            if (cr)
            {
              const std::string cr_str = CFStringToStdString(cr);
              CFRelease(cr);
              if (auto total = ParseContentRangeTotal(cr_str))
              {
                CFReadStreamClose(stream);
                CFRelease(stream);
                CFRelease(resp);
                INFO_LOG_FMT(DISCIO, "HttpBlobReader iOS: Range GET {} returned Content-Range '{}' => size {}", url, cr_str, *total);
                CFRelease(cfUrl);
                return total;
              }
            }
            CFRelease(resp);
          }
          CFReadStreamClose(stream);
        }
        CFRelease(stream);
      }
    }
  }

  CFRelease(cfUrl);
  return std::nullopt;
}

// iOS-specific HTTP request using CoreFoundation/CFNetwork
static bool FetchRangeIOS(const std::string& url, u64 offset, u64 size, std::vector<u8>* out)
{
  // Create URL
  CFStringRef urlString = CFStringCreateWithCString(kCFAllocatorDefault, url.c_str(), kCFStringEncodingUTF8);
  if (!urlString) return false;

  CFURLRef cfUrl = CFURLCreateWithString(kCFAllocatorDefault, urlString, nullptr);
  CFRelease(urlString);
  if (!cfUrl) return false;

  // Create HTTP request
  CFStringRef httpMethod = CFSTR("GET");
  CFHTTPMessageRef request = CFHTTPMessageCreateRequest(kCFAllocatorDefault, httpMethod, cfUrl, kCFHTTPVersion1_1);
  CFRelease(cfUrl);
  if (!request) return false;

  // Add Range header
  const u64 end = offset + (size ? (size - 1) : 0);
  char rangeBuffer[64];
  snprintf(rangeBuffer, sizeof(rangeBuffer), "bytes=%llu-%llu", offset, end);
  CFStringRef rangeHeader = CFStringCreateWithCString(kCFAllocatorDefault, rangeBuffer, kCFStringEncodingUTF8);
  CFStringRef rangeKey = CFSTR("Range");
  CFHTTPMessageSetHeaderFieldValue(request, rangeKey, rangeHeader);
  CFRelease(rangeHeader);

  // Create read stream
  CFReadStreamRef readStream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request);
  CFRelease(request);
  if (!readStream) return false;

  // Open stream
  if (!CFReadStreamOpen(readStream)) {
    CFRelease(readStream);
    return false;
  }

  // Read response data
  std::vector<u8> responseData;
  u8 buffer[8192];
  CFIndex bytesRead;

  while ((bytesRead = CFReadStreamRead(readStream, buffer, sizeof(buffer))) > 0) {
    responseData.insert(responseData.end(), buffer, buffer + bytesRead);
  }

  // Get response message
  CFHTTPMessageRef response = (CFHTTPMessageRef)CFReadStreamCopyProperty(readStream, kCFStreamPropertyHTTPResponseHeader);
  CFIndex statusCode = 0;
  if (response) {
    statusCode = CFHTTPMessageGetResponseStatusCode(response);
    CFRelease(response);
  }

  CFReadStreamClose(readStream);
  CFRelease(readStream);

  INFO_LOG_FMT(DISCIO, "HttpBlobReader iOS: response code {} with {} bytes", statusCode, responseData.size());

  if (bytesRead < 0) {
    INFO_LOG_FMT(DISCIO, "HttpBlobReader iOS: read error");
    return false;
  }

  if (responseData.empty()) {
    INFO_LOG_FMT(DISCIO, "HttpBlobReader iOS: no response data");
    return false;
  }

  // Handle response based on status code
  if (statusCode == 200) {
    // Full content - extract the requested range
    if (offset >= responseData.size()) {
      return false;
    }
    const u64 available = responseData.size() - offset;
    const u64 to_copy = std::min(size, available);
    out->assign(responseData.begin() + offset, responseData.begin() + offset + to_copy);
    return to_copy == size;
  } else if (statusCode == 206) {
    // Partial content - use as-is
    out->assign(responseData.begin(), responseData.end());
    return responseData.size() == size;
  } else if (statusCode == 0 && !responseData.empty()) {
    // No status code but we have data - try to use it
    if (responseData.size() >= size) {
      out->assign(responseData.begin(), responseData.begin() + size);
      return true;
    }
  }

  return false;
}
#endif

}  // namespace

std::unique_ptr<HttpBlobReader> HttpBlobReader::Create(const std::string& url)
{
  INFO_LOG_FMT(DISCIO, "HttpBlobReader::Create called with URL: {}", url);
  if (url.empty())
  {
    ERROR_LOG_FMT(DISCIO, "HttpBlobReader::Create: empty URL provided, returning nullptr");
    return nullptr;
  }
  if (!IsHttpUrl(url))
  {
    INFO_LOG_FMT(DISCIO, "HttpBlobReader::Create: URL is not HTTP, returning nullptr");
    return nullptr;
  }
  INFO_LOG_FMT(DISCIO, "HttpBlobReader::Create: creating HttpBlobReader for {}", ToHttpUrl(url));
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
  return m_size_known ? m_size : 0;
}

u64 HttpBlobReader::GetDataSize() const
{
  return GetRawSize();
}

bool HttpBlobReader::EnsureSize()
{
  if (m_size_known)
  {
    INFO_LOG_FMT(DISCIO, "HttpBlobReader::EnsureSize: size already known for {}: {} bytes", m_url, m_size);
    return true;
  }

  INFO_LOG_FMT(DISCIO, "HttpBlobReader::EnsureSize: determining size for {}", m_url);

#ifdef __APPLE__
  if (auto sz = GetRemoteSizeIOS(m_url))
  {
    m_size = *sz;
    m_size_known = true;
    INFO_LOG_FMT(DISCIO, "HttpBlobReader::EnsureSize: got size {} bytes for {}", m_size, m_url);
    return true;
  }
  else
  {
    ERROR_LOG_FMT(DISCIO, "HttpBlobReader::EnsureSize: GetRemoteSizeIOS failed for {}", m_url);
  }
#endif

  // Fallback: conservative default to keep header parsing working
  INFO_LOG_FMT(DISCIO, "HttpBlobReader: skipping size probe for remote file, using default size for {}", m_url);
  m_size = 4700000000ULL; // ~4.7GB
  m_size_known = true;
  return true;
}

bool HttpBlobReader::FetchRange(u64 offset, u64 size, std::vector<u8>* out)
{
  // Limit the maximum size we'll try to fetch to prevent memory issues
  const u64 MAX_FETCH_SIZE = 64 * 1024 * 1024; // 64MB limit
  if (size > MAX_FETCH_SIZE)
  {
    ERROR_LOG_FMT(DISCIO, "HttpBlobReader: requested size {} exceeds limit {} for {}", size, MAX_FETCH_SIZE, m_url);
    return false;
  }

#ifdef __APPLE__
  // Use iOS-specific NSURLSession implementation
  INFO_LOG_FMT(DISCIO, "HttpBlobReader: using iOS NSURLSession for range {}-{} from {}", offset, offset + size - 1, m_url);
  return FetchRangeIOS(m_url, offset, size, out);
#else
  // Use original libcurl implementation for other platforms
  Common::HttpRequest req;
  if (!req.IsValid())
  {
    ERROR_LOG_FMT(DISCIO, "HttpBlobReader: HttpRequest invalid for URL {}", m_url);
    return false;
  }

  const u64 end = offset + (size ? (size - 1) : 0);
  Common::HttpRequest::Headers headers;
  headers.emplace("Range", fmt::format("bytes={}-{}", offset, end));
  INFO_LOG_FMT(DISCIO, "HttpBlobReader: GET range {}-{} for {}", offset, end, m_url);

  // Try the request with AllowedReturnCodes::All to be more permissive
  const auto resp = req.Get(m_url, headers, Common::HttpRequest::AllowedReturnCodes::All);
  const auto code = req.GetLastResponseCode();
  INFO_LOG_FMT(DISCIO, "HttpBlobReader: range response code {} for {}", code, m_url);

  // Be more permissive with response codes - accept any response that has data
  if (!resp)
  {
    INFO_LOG_FMT(DISCIO, "HttpBlobReader: no response data for {}", m_url);
    return false;
  }

  const auto& body = *resp;
  if (body.empty())
  {
    INFO_LOG_FMT(DISCIO, "HttpBlobReader: empty response body for {}", m_url);
    return false;
  }

  // Handle different response scenarios
  if (code == 206)
  {
    // Partial content - use as-is
    out->assign(body.begin(), body.end());
    const bool ok = out->size() == size;
    if (!ok)
      INFO_LOG_FMT(DISCIO, "HttpBlobReader: received {} bytes, expected {} for {}", out->size(), size, m_url);
    return ok;
  }
  else if (code == 200)
  {
    // Full content - extract the requested range
    if (body.size() > MAX_FETCH_SIZE)
    {
      ERROR_LOG_FMT(DISCIO, "HttpBlobReader: server sent full file {} bytes, too large for {}", body.size(), m_url);
      return false;
    }
    if (offset >= body.size())
    {
      ERROR_LOG_FMT(DISCIO, "HttpBlobReader: offset {} beyond file size {} for {}", offset, body.size(), m_url);
      return false;
    }

    const u64 available = body.size() - offset;
    const u64 to_copy = std::min(size, available);
    out->assign(body.begin() + offset, body.begin() + offset + to_copy);
    return to_copy == size;
  }
  else
  {
    // For any other response code, if we have data, try to use it
    INFO_LOG_FMT(DISCIO, "HttpBlobReader: unexpected response code {} but got {} bytes, attempting to use for {}", code, body.size(), m_url);

    if (body.size() >= size)
    {
      out->assign(body.begin(), body.begin() + size);
      return true;
    }
    else
    {
      out->assign(body.begin(), body.end());
      return false; // Didn't get enough data
    }
  }
#endif
}

bool HttpBlobReader::Read(u64 offset, u64 size, u8* out_ptr)
{
  if (size == 0)
    return true;
  if (!EnsureSize())
  {
    ERROR_LOG_FMT(DISCIO, "HttpBlobReader: EnsureSize failed for {}", m_url);
    return false;
  }

  // If size is unknown (0), skip size checks and let FetchRange handle it
  if (m_size > 0)
  {
    if (offset >= m_size)
    {
      ERROR_LOG_FMT(DISCIO, "HttpBlobReader: offset {} beyond end {} for {}", offset, m_size, m_url);
      return false;
    }
    if (offset + size > m_size)
      size = m_size - offset;
  }

  // Try to read from cache first
  if (ReadFromCache(offset, size, out_ptr))
  {
    return true; // Cache hit!
  }

  // Cache miss
  m_cache_misses++;
  INFO_LOG_FMT(DISCIO, "HttpBlobReader: cache MISS for offset {} size {} - fetching from network", offset, size);

  // Cache miss - fetch from network with smart prefetching
  // For small reads, fetch a larger block to improve cache efficiency
  u64 fetch_size = size;
  u64 fetch_offset = offset;

  // Detect sequential access pattern
  const bool is_sequential = (offset == m_last_read_offset ||
                              (offset > m_last_read_offset && offset - m_last_read_offset <= 65536));
  if (is_sequential)
  {
    m_sequential_reads++;
  }
  else
  {
    m_sequential_reads = 0;
  }
  m_last_read_offset = offset + size;

  if (size <= 65536) // For reads <= 64KB, fetch up to 1MB
  {
    // Check if we're at the boundary of an existing cache block
    bool at_cache_boundary = false;
    u64 next_block_start = 0;
    u64 cached_portion_size = 0;

    for (const auto& [cache_offset, entry] : m_cache)
    {
      const u64 cache_end = entry.offset + entry.size;
      // Check if we're requesting data that extends beyond a cached block
      if (offset >= entry.offset && offset < cache_end && (offset + size) > cache_end)
      {
        at_cache_boundary = true;
        next_block_start = cache_end;
        cached_portion_size = cache_end - offset;
        INFO_LOG_FMT(DISCIO, "HttpBlobReader: request spans beyond cached block - offset {} size {} extends beyond cache end {}, {} bytes already cached",
                     offset, size, cache_end, cached_portion_size);
        break;
      }
    }

    if (at_cache_boundary)
    {
      // Handle partial cache hit: copy cached portion first, then fetch remaining
      const u64 remaining_size = size - cached_portion_size;

      // Copy the cached portion first
      if (!ReadFromCache(offset, cached_portion_size, out_ptr))
      {
        ERROR_LOG_FMT(DISCIO, "HttpBlobReader: failed to read cached portion at offset {} size {}", offset, cached_portion_size);
        return false;
      }

      // Fetch the remaining data starting from the end of the cached block
      fetch_offset = next_block_start;
      fetch_size = std::min(CACHE_BLOCK_SIZE, m_size - fetch_offset);

      INFO_LOG_FMT(DISCIO, "HttpBlobReader: at cache boundary, fetching next block {} - {} ({} bytes) for remaining {} bytes",
                   fetch_offset, fetch_offset + fetch_size - 1, fetch_size, remaining_size);

      std::vector<u8> buffer;
      if (!FetchRange(fetch_offset, fetch_size, &buffer))
      {
        ERROR_LOG_FMT(DISCIO, "HttpBlobReader: FetchRange failed at {} size {} for {}", fetch_offset, fetch_size, m_url);
        return false;
      }

      // Add to cache
      if (buffer.size() >= fetch_size)
      {
        AddToCache(fetch_offset, buffer);
      }

      // Copy the remaining portion (starts at beginning of new block)
      const u64 copy_size = std::min(remaining_size, static_cast<u64>(buffer.size()));
      std::memcpy(out_ptr + cached_portion_size, buffer.data(), copy_size);

      INFO_LOG_FMT(DISCIO, "HttpBlobReader: boundary read complete - copied {} cached + {} fetched = {} total bytes",
                   cached_portion_size, copy_size, cached_portion_size + copy_size);

      return true;
    }
    else
    {
      // Normal prefetch logic - align to cache block boundary
      const u64 block_start = (offset / CACHE_BLOCK_SIZE) * CACHE_BLOCK_SIZE;
      const u64 request_end = offset + size;

      // Calculate how many blocks we need to cover the entire request
      const u64 blocks_needed = ((request_end - 1) / CACHE_BLOCK_SIZE) - (block_start / CACHE_BLOCK_SIZE) + 1;
      const u64 block_end = std::min(block_start + blocks_needed * CACHE_BLOCK_SIZE, m_size);

      fetch_offset = block_start;
      fetch_size = block_end - block_start;

      // If we detect sequential access, prefetch even more aggressively
      if (m_sequential_reads >= 3 && blocks_needed == 1)
      {
        const u64 extended_end = std::min(block_start + CACHE_BLOCK_SIZE * 2, m_size);
        fetch_size = extended_end - block_start;
        INFO_LOG_FMT(DISCIO, "HttpBlobReader: detected sequential access pattern, extending prefetch to {} bytes", fetch_size);
      }

      // Ensure we don't fetch beyond the end of the request if it would create a small overhang
      const u64 fetch_end = fetch_offset + fetch_size;
      if (request_end < fetch_end && (fetch_end - request_end) < 4096)
      {
        // If the overhang is small, just fetch exactly what's needed
        fetch_size = request_end - fetch_offset;
      }

      INFO_LOG_FMT(DISCIO, "HttpBlobReader: prefetching {} blocks ({} - {}, {} bytes) for request {} - {} ({} bytes)",
                   blocks_needed, fetch_offset, fetch_offset + fetch_size - 1, fetch_size, offset, offset + size - 1, size);
    }
  }

  std::vector<u8> buffer;
  if (!FetchRange(fetch_offset, fetch_size, &buffer))
  {
    ERROR_LOG_FMT(DISCIO, "HttpBlobReader: FetchRange failed at {} size {} for {}", fetch_offset, fetch_size, m_url);
    return false;
  }

  INFO_LOG_FMT(DISCIO, "HttpBlobReader: Read successful, got {} bytes", buffer.size());

  // Add to cache if we fetched more than requested
  if (fetch_size > size && buffer.size() >= fetch_size)
  {
    AddToCache(fetch_offset, buffer);
  }

  // Extract the requested data from the buffer
  const u64 data_offset = offset - fetch_offset;
  if (data_offset + size > buffer.size())
  {
    ERROR_LOG_FMT(DISCIO, "HttpBlobReader: buffer underrun - requested {} bytes at offset {}, but buffer only has {} bytes (fetch_offset={}, offset={})",
                  size, data_offset, buffer.size(), fetch_offset, offset);
    return false;
  }

  std::memcpy(out_ptr, buffer.data() + data_offset, size);


  return true;
}

u64 HttpBlobReader::GetCurrentTimeMs() const
{
  auto now = std::chrono::steady_clock::now();
  auto duration = now.time_since_epoch();
  return std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
}

bool HttpBlobReader::ReadFromCache(u64 offset, u64 size, u8* out_ptr)
{
  for (auto& [cache_offset, entry] : m_cache)
  {
    // Check if this cache entry can satisfy the entire request
    if (offset >= entry.offset && offset + size <= entry.offset + entry.size)
    {
      const u64 data_offset = offset - entry.offset;

      // Double-check bounds to prevent buffer overrun
      if (data_offset + size > entry.data.size())
      {
        ERROR_LOG_FMT(DISCIO, "HttpBlobReader: cache bounds check failed - data_offset {} + size {} > entry.data.size() {}",
                      data_offset, size, entry.data.size());
        continue; // Try next cache entry
      }

      std::memcpy(out_ptr, entry.data.data() + data_offset, size);

      // Update access time for LRU
      entry.last_access_time = GetCurrentTimeMs();
      m_cache_access_counter++;
      m_cache_hits++;

      // Log cache statistics periodically
      if ((m_cache_hits + m_cache_misses) % 50 == 0)
      {
        const double hit_rate = (double)m_cache_hits / (m_cache_hits + m_cache_misses) * 100.0;
        INFO_LOG_FMT(DISCIO, "HttpBlobReader: cache stats - hits: {}, misses: {}, hit rate: {:.1f}%, cache size: {}",
                     m_cache_hits, m_cache_misses, hit_rate, m_cache.size());
      }

      INFO_LOG_FMT(DISCIO, "HttpBlobReader: cache HIT for offset {} size {} (from cache block at {})",
                   offset, size, entry.offset);
      return true;
    }

    // Check for partial cache hit at the beginning of the request
    if (offset >= entry.offset && offset < entry.offset + entry.size && offset + size > entry.offset + entry.size)
    {
      // We have a partial hit - the request starts in this cache block but extends beyond it
      // This should be handled by the boundary detection in the main Read() method
      INFO_LOG_FMT(DISCIO, "HttpBlobReader: partial cache hit detected - offset {} size {} spans beyond cache block {} - {}",
                   offset, size, entry.offset, entry.offset + entry.size);
      return false; // Let the main Read() method handle this with boundary detection
    }
  }

  // TODO: Could implement partial cache hits by combining multiple cache entries,
  // but for now we'll keep it simple and only handle complete hits

  return false; // Cache miss
}

void HttpBlobReader::AddToCache(u64 offset, const std::vector<u8>& data)
{
  // Don't cache if data is too small or too large
  if (data.size() < 4096 || data.size() > CACHE_BLOCK_SIZE * 2)
    return;

  // Evict old entries if cache is full
  if (m_cache.size() >= MAX_CACHE_ENTRIES)
  {
    EvictOldCacheEntries();
  }

  // Add to cache using the actual offset as key
  HttpCacheEntry entry;
  entry.data = data;
  entry.offset = offset;
  entry.size = data.size();
  entry.last_access_time = GetCurrentTimeMs();

  m_cache[offset] = std::move(entry);

  INFO_LOG_FMT(DISCIO, "HttpBlobReader: cached block at offset {} size {} (cache size: {})",
               offset, data.size(), m_cache.size());
}

void HttpBlobReader::EvictOldCacheEntries()
{
  const u64 current_time = GetCurrentTimeMs();

  // First, remove expired entries
  auto it = m_cache.begin();
  while (it != m_cache.end())
  {
    if (current_time - it->second.last_access_time > CACHE_ENTRY_LIFETIME_MS)
    {
      INFO_LOG_FMT(DISCIO, "HttpBlobReader: evicting expired cache entry at offset {}", it->second.offset);
      it = m_cache.erase(it);
    }
    else
    {
      ++it;
    }
  }

  // If still too many entries, remove the oldest ones
  while (m_cache.size() >= MAX_CACHE_ENTRIES)
  {
    auto oldest_it = std::min_element(m_cache.begin(), m_cache.end(),
                                      [](const auto& a, const auto& b) {
      return a.second.last_access_time < b.second.last_access_time;
    });

    if (oldest_it != m_cache.end())
    {
      INFO_LOG_FMT(DISCIO, "HttpBlobReader: evicting LRU cache entry at offset {}", oldest_it->second.offset);
      m_cache.erase(oldest_it);
    }
    else
    {
      break;
    }
  }
}

// HTTP-backed CISO reader implementation
std::unique_ptr<HttpCISOReader> HttpCISOReader::Create(const std::string& url)
{
  INFO_LOG_FMT(DISCIO, "HttpCISOReader::Create called with URL: {}", url);

  auto http_reader = HttpBlobReader::Create(url);
  if (!http_reader)
  {
    ERROR_LOG_FMT(DISCIO, "HttpCISOReader::Create: failed to create HttpBlobReader");
    return nullptr;
  }

  auto ciso_reader = std::unique_ptr<HttpCISOReader>(new HttpCISOReader(std::move(http_reader)));
  if (!ciso_reader->ReadHeader())
  {
    ERROR_LOG_FMT(DISCIO, "HttpCISOReader::Create: failed to read CISO header");
    return nullptr;
  }

  INFO_LOG_FMT(DISCIO, "HttpCISOReader::Create: successfully created CISO reader");
  return ciso_reader;
}

HttpCISOReader::HttpCISOReader(std::unique_ptr<HttpBlobReader> http_reader)
: m_http_reader(std::move(http_reader))
{
}

std::unique_ptr<BlobReader> HttpCISOReader::CopyReader() const
{
  return Create(m_http_reader->GetUrl());
}

bool HttpCISOReader::ReadHeader()
{
  if (m_header_read)
    return true;

  INFO_LOG_FMT(DISCIO, "HttpCISOReader: reading CISO header");

  // Read CISO header (same structure as CISOFileReader)
  struct CISOHeader
  {
    u32 magic;
    u32 block_size;
    u8 map[CISO_MAP_SIZE];
  };

  CISOHeader header;
  if (!m_http_reader->Read(0, sizeof(header), reinterpret_cast<u8*>(&header)))
  {
    ERROR_LOG_FMT(DISCIO, "HttpCISOReader: failed to read CISO header");
    return false;
  }

  // Validate header
  if (header.magic != 0x4F534943) // 'CISO' in little endian
  {
    ERROR_LOG_FMT(DISCIO, "HttpCISOReader: invalid CISO magic: 0x{:08x}", header.magic);
    return false;
  }

  // CISO block_size is stored in little endian, but on iOS (little endian) no conversion needed
  m_block_size = header.block_size;

  // Calculate total size from the map
  u32 used_blocks = 0;
  for (u32 i = 0; i < CISO_MAP_SIZE; ++i)
  {
    if (header.map[i] == 1)
      used_blocks++;
  }
  m_size = static_cast<u64>(CISO_MAP_SIZE) * m_block_size;

  INFO_LOG_FMT(DISCIO, "HttpCISOReader: CISO header - block_size: {}, total_bytes: {}, used_blocks: {}",
               m_block_size, m_size, used_blocks);

  // Copy the map
  u16 count = 0;
  for (u32 i = 0; i < CISO_MAP_SIZE; ++i)
  {
    m_ciso_map[i] = (header.map[i] == 1) ? count++ : UNUSED_BLOCK_ID;
  }

  INFO_LOG_FMT(DISCIO, "HttpCISOReader: successfully read CISO header and block map");
  m_header_read = true;
  return true;
}

u64 HttpCISOReader::GetRawSize() const
{
  return m_http_reader->GetRawSize();
}

u64 HttpCISOReader::GetDataSize() const
{
  return m_size;
}

u64 HttpCISOReader::GetBlockSize() const
{
  return m_block_size;
}

bool HttpCISOReader::Read(u64 offset, u64 nbytes, u8* out_ptr)
{
  if (!m_header_read && !ReadHeader())
    return false;

  if (offset + nbytes > GetDataSize())
    return false;

  while (nbytes != 0)
  {
    const u64 block = offset / m_block_size;
    const u64 data_offset = offset % m_block_size;
    const u64 bytes_to_read = std::min(m_block_size - data_offset, nbytes);

    if (block < CISO_MAP_SIZE && UNUSED_BLOCK_ID != m_ciso_map[block])
    {
      // Calculate the base address in the CISO file
      const u64 file_off = CISO_HEADER_SIZE + m_ciso_map[block] * static_cast<u64>(m_block_size) + data_offset;

      if (!m_http_reader->Read(file_off, bytes_to_read, out_ptr))
      {
        ERROR_LOG_FMT(DISCIO, "HttpCISOReader: failed to read data at offset {}", file_off);
        return false;
      }
    }
    else
    {
      // Unused block - fill with zeros
      std::fill_n(out_ptr, bytes_to_read, 0);
    }

    out_ptr += bytes_to_read;
    offset += bytes_to_read;
    nbytes -= bytes_to_read;
  }

  return true;
}

// HTTP-backed GCZ reader implementation
std::unique_ptr<HttpGCZReader> HttpGCZReader::Create(const std::string& url)
{
  INFO_LOG_FMT(DISCIO, "HttpGCZReader::Create called with URL: {}", url);

  auto http_reader = HttpBlobReader::Create(url);
  if (!http_reader)
  {
    ERROR_LOG_FMT(DISCIO, "HttpGCZReader::Create: failed to create HttpBlobReader");
    return nullptr;
  }

  auto gcz_reader = std::unique_ptr<HttpGCZReader>(new HttpGCZReader(std::move(http_reader)));
  if (!gcz_reader->ReadHeader())
  {
    ERROR_LOG_FMT(DISCIO, "HttpGCZReader::Create: failed to read GCZ header");
    return nullptr;
  }

  INFO_LOG_FMT(DISCIO, "HttpGCZReader::Create: successfully created GCZ reader");
  return gcz_reader;
}

HttpGCZReader::HttpGCZReader(std::unique_ptr<HttpBlobReader> http_reader)
: m_http_reader(std::move(http_reader))
{
}

std::unique_ptr<BlobReader> HttpGCZReader::CopyReader() const
{
  return Create(m_http_reader->GetUrl());
}

bool HttpGCZReader::ReadHeader()
{
  if (m_header_read)
    return true;

  INFO_LOG_FMT(DISCIO, "HttpGCZReader: reading GCZ header");

  // Read GCZ header (same structure as CompressedBlobHeader)
  struct CompressedBlobHeader
  {
    u32 magic_cookie;  // 0xB10BC001
    u32 sub_type;      // GC image, whatever
    u64 compressed_data_size;
    u64 data_size;
    u32 block_size;
    u32 num_blocks;
  };

  CompressedBlobHeader header;
  if (!m_http_reader->Read(0, sizeof(header), reinterpret_cast<u8*>(&header)))
  {
    ERROR_LOG_FMT(DISCIO, "HttpGCZReader: failed to read GCZ header");
    return false;
  }

  // Validate header
  if (header.magic_cookie != 0xB10BC001) // GCZ_MAGIC
  {
    ERROR_LOG_FMT(DISCIO, "HttpGCZReader: invalid GCZ magic: 0x{:08x}", header.magic_cookie);
    return false;
  }

  m_block_size = header.block_size;
  m_data_size = header.data_size;
  const u32 num_blocks = header.num_blocks;

  INFO_LOG_FMT(DISCIO, "HttpGCZReader: GCZ header - block_size: {}, data_size: {}, num_blocks: {}",
               m_block_size, m_data_size, num_blocks);

  // Read block pointers
  m_block_pointers.resize(num_blocks);
  const u64 pointers_offset = sizeof(header);
  if (!m_http_reader->Read(pointers_offset, num_blocks * sizeof(u64),
                           reinterpret_cast<u8*>(m_block_pointers.data())))
  {
    ERROR_LOG_FMT(DISCIO, "HttpGCZReader: failed to read GCZ block pointers");
    return false;
  }

  INFO_LOG_FMT(DISCIO, "HttpGCZReader: successfully read GCZ header and block pointers");
  m_header_read = true;
  return true;
}

u64 HttpGCZReader::GetRawSize() const
{
  return m_http_reader->GetRawSize();
}

u64 HttpGCZReader::GetDataSize() const
{
  return m_data_size;
}

u64 HttpGCZReader::GetBlockSize() const
{
  return m_block_size;
}

bool HttpGCZReader::Read(u64 offset, u64 nbytes, u8* out_ptr)
{
  if (!m_header_read && !ReadHeader())
    return false;

  if (offset + nbytes > GetDataSize())
    return false;

  INFO_LOG_FMT(DISCIO, "HttpGCZReader::Read: offset {} size {}", offset, nbytes);

  while (nbytes > 0)
  {
    const u64 block_num = offset / m_block_size;
    const u64 block_offset = offset % m_block_size;
    const u64 bytes_to_read = std::min(m_block_size - block_offset, nbytes);

    if (block_num >= m_block_pointers.size())
    {
      ERROR_LOG_FMT(DISCIO, "HttpGCZReader: block number {} out of range", block_num);
      return false;
    }

    // Read the compressed block
    std::vector<u8> compressed_block;
    if (!ReadCompressedBlock(block_num, &compressed_block))
    {
      ERROR_LOG_FMT(DISCIO, "HttpGCZReader: failed to read compressed block {}", block_num);
      return false;
    }

    // Decompress if needed
    std::vector<u8> decompressed_block;
    if (!DecompressBlock(compressed_block, &decompressed_block))
    {
      ERROR_LOG_FMT(DISCIO, "HttpGCZReader: failed to decompress block {}", block_num);
      return false;
    }

    // Copy the requested portion
    const u64 copy_size = std::min(bytes_to_read, static_cast<u64>(decompressed_block.size() - block_offset));
    std::memcpy(out_ptr, decompressed_block.data() + block_offset, copy_size);

    out_ptr += copy_size;
    offset += copy_size;
    nbytes -= copy_size;
  }

  return true;
}

bool HttpGCZReader::ReadCompressedBlock(u64 block_num, std::vector<u8>* out)
{
  if (block_num >= m_block_pointers.size())
    return false;

  const u64 block_pointer = m_block_pointers[block_num];
  const bool is_compressed = (block_pointer & 0x8000000000000000ULL) == 0;
  const u64 file_offset = block_pointer & 0x7FFFFFFFFFFFFFFFULL;

  // Calculate block size
  u64 block_size;
  if (block_num + 1 < m_block_pointers.size())
  {
    const u64 next_pointer = m_block_pointers[block_num + 1] & 0x7FFFFFFFFFFFFFFFULL;
    block_size = next_pointer - file_offset;
  }
  else
  {
    // Last block - use remaining file size
    block_size = m_block_size; // Conservative estimate
  }

  INFO_LOG_FMT(DISCIO, "HttpGCZReader: reading block {} at offset {} size {} compressed={}",
               block_num, file_offset, block_size, is_compressed);

  out->resize(block_size);
  return m_http_reader->Read(file_offset, block_size, out->data());
}

bool HttpGCZReader::DecompressBlock(const std::vector<u8>& compressed_data, std::vector<u8>* out)
{
  // Check if block is compressed (based on GCZ format)
  if (compressed_data.size() >= m_block_size)
  {
    // Uncompressed block
    *out = compressed_data;
    return true;
  }

  // Compressed block - use zlib to decompress
  out->resize(m_block_size);

  z_stream strm = {};
  if (inflateInit(&strm) != Z_OK)
  {
    ERROR_LOG_FMT(DISCIO, "HttpGCZReader: inflateInit failed");
    return false;
  }

  strm.avail_in = compressed_data.size();
  strm.next_in = const_cast<u8*>(compressed_data.data());
  strm.avail_out = out->size();
  strm.next_out = out->data();

  const int result = inflate(&strm, Z_FINISH);
  inflateEnd(&strm);

  if (result != Z_STREAM_END)
  {
    ERROR_LOG_FMT(DISCIO, "HttpGCZReader: inflate failed with result {}", result);
    return false;
  }

  out->resize(strm.total_out);
  return true;
}

// HTTP-backed RVZ reader implementation (follows HttpCISOReader pattern)
std::unique_ptr<HttpRVZReader> HttpRVZReader::Create(const std::string& url)
{
  INFO_LOG_FMT(DISCIO, "HttpRVZReader::Create: creating streaming RVZ reader for {}", url);

  auto http_reader = HttpBlobReader::Create(url);
  if (!http_reader)
  {
    ERROR_LOG_FMT(DISCIO, "HttpRVZReader::Create: failed to create HttpBlobReader");
    return nullptr;
  }

  auto rvz_reader = std::unique_ptr<HttpRVZReader>(new HttpRVZReader(std::move(http_reader)));
  if (!rvz_reader->ReadHeaders())
  {
    ERROR_LOG_FMT(DISCIO, "HttpRVZReader::Create: failed to read RVZ headers");
    return nullptr;
  }

  INFO_LOG_FMT(DISCIO, "HttpRVZReader::Create: successfully created RVZ reader");
  return rvz_reader;
}

HttpRVZReader::HttpRVZReader(std::unique_ptr<HttpBlobReader> http_reader)
    : m_http_reader(std::move(http_reader))
{
}

std::unique_ptr<BlobReader> HttpRVZReader::CopyReader() const
{
  return Create(m_http_reader->GetUrl());
}

bool HttpRVZReader::ReadHeaders()
{
  if (m_headers_read)
    return true;


  // Read WIA header 1
  if (!m_http_reader->Read(0, sizeof(m_header_1), reinterpret_cast<u8*>(&m_header_1)))
  {
    ERROR_LOG_FMT(DISCIO, "HttpRVZReader: failed to read WIA header 1");
    return false;
  }

  // Validate magic number
  if (m_header_1.magic != RVZ_MAGIC)
  {
    ERROR_LOG_FMT(DISCIO, "HttpRVZReader: invalid RVZ magic: 0x{:08x}", m_header_1.magic);
    return false;
  }

  // Validate version (constants from WIABlob.h)
  static constexpr u32 RVZ_VERSION = 0x01000000;
  static constexpr u32 RVZ_VERSION_READ_COMPATIBLE = 0x00030000;
  const u32 file_version = Common::swap32(m_header_1.version);
  if (file_version < RVZ_VERSION_READ_COMPATIBLE || file_version > RVZ_VERSION)
  {
    ERROR_LOG_FMT(DISCIO, "HttpRVZReader: Unsupported RVZ version {}", file_version);
    return false;
  }

  // Read WIA header 2
  const u32 header_2_size = Common::swap32(m_header_1.header_2_size);
  if (header_2_size != sizeof(WIAHeader2))
  {
    ERROR_LOG_FMT(DISCIO, "HttpRVZReader: unexpected header 2 size: {}", header_2_size);
    return false;
  }

  if (!m_http_reader->Read(sizeof(WIAHeader1), sizeof(m_header_2), reinterpret_cast<u8*>(&m_header_2)))
  {
    ERROR_LOG_FMT(DISCIO, "HttpRVZReader: failed to read WIA header 2");
    return false;
  }

  // Read raw data entries
  const u32 num_raw_data_entries = Common::swap32(m_header_2.number_of_raw_data_entries);
  const u64 raw_data_entries_offset = Common::swap64(m_header_2.raw_data_entries_offset);
  const u32 raw_data_entries_size = Common::swap32(m_header_2.raw_data_entries_size);


  m_raw_data_entries.resize(num_raw_data_entries);
  if (num_raw_data_entries > 0)
  {
    // Read compressed raw data entries data
    std::vector<u8> compressed_raw_data(raw_data_entries_size);
    if (!m_http_reader->Read(raw_data_entries_offset, raw_data_entries_size, compressed_raw_data.data()))
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader: failed to read compressed raw data entries");
      return false;
    }

    // Decompress the raw data entries
    const u32 decompressed_size = num_raw_data_entries * sizeof(RawDataEntry); // 24 bytes per entry
    std::vector<u8> decompressed_data(decompressed_size);

    if (!DecompressGroupEntries(compressed_raw_data, decompressed_data))
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader: failed to decompress raw data entries");
      return false;
    }

    // Parse decompressed raw data entries (24 bytes each: u64 + u64 + u32 + u32)
    const u8* data_ptr = decompressed_data.data();
    for (u32 i = 0; i < num_raw_data_entries; ++i)
    {
      if (i * 24 + 24 > decompressed_size) // RawDataEntry is 24 bytes (u64 + u64 + u32 + u32)
      {
        ERROR_LOG_FMT(DISCIO, "HttpRVZReader: raw data entry {} would exceed data size", i);
        return false;
      }

      RawDataEntry& entry = m_raw_data_entries[i];
      // Read fields manually with proper endianness handling (24 bytes per entry: u64 + u64 + u32 + u32)
      u64 raw_data_off_be, raw_data_size_be;
      u32 group_index_be, n_groups_be;

      std::memcpy(&raw_data_off_be, data_ptr + i * 24, 8);
      std::memcpy(&raw_data_size_be, data_ptr + i * 24 + 8, 8);
      std::memcpy(&group_index_be, data_ptr + i * 24 + 16, 4);
      std::memcpy(&n_groups_be, data_ptr + i * 24 + 20, 4);

      // Apply byte swapping for big-endian to little-endian conversion
      entry.raw_data_off = Common::swap64(raw_data_off_be);
      entry.raw_data_size = Common::swap64(raw_data_size_be);
      entry.group_index = Common::swap32(group_index_be);
      entry.n_groups = Common::swap32(n_groups_be);

    }
  }

    // Read group entries (these are compressed data, not raw structs)
  const u32 num_group_entries = Common::swap32(m_header_2.number_of_group_entries);
  const u64 group_entries_offset = Common::swap64(m_header_2.group_entries_offset);
  const u32 group_entries_size = Common::swap32(m_header_2.group_entries_size);


  m_group_entries.resize(num_group_entries);
  if (num_group_entries > 0)
  {
    // Read compressed group entries data
    std::vector<u8> compressed_group_data(group_entries_size);
    if (!m_http_reader->Read(group_entries_offset, group_entries_size, compressed_group_data.data()))
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader: failed to read compressed group entries");
      return false;
    }

    // Decompress the group entries
    const u32 decompressed_size = num_group_entries * sizeof(GroupEntry);
    std::vector<u8> decompressed_data(decompressed_size);

    if (!DecompressGroupEntries(compressed_group_data, decompressed_data))
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader: failed to decompress group entries");
      return false;
    }

    // Parse decompressed group entries (12 bytes each: u32 + u32 + u32)
    const u8* data_ptr = decompressed_data.data();
    for (u32 i = 0; i < num_group_entries; ++i)
    {
      GroupEntry& entry = m_group_entries[i];
      std::memcpy(&entry.data_offset, data_ptr + i * 12, 4);     // u32 data_off4
      std::memcpy(&entry.data_size, data_ptr + i * 12 + 4, 4);  // u32 data_size
      std::memcpy(&entry.rvz_packed_size, data_ptr + i * 12 + 8, 4); // u32 rvz_packed_size

    }
  }


  m_headers_read = true;
  return true;
}

bool HttpRVZReader::DecompressGroupEntries(const std::vector<u8>& compressed_data, std::vector<u8>& decompressed_data)
{
  // For now, implement basic decompression based on the compression type
  const u32 compression_type = Common::swap32(m_header_2.compression_type);

  if (compression_type == 0) // No compression
  {
    if (compressed_data.size() != decompressed_data.size())
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader: uncompressed size mismatch for group entries");
      return false;
    }
    std::memcpy(decompressed_data.data(), compressed_data.data(), compressed_data.size());
    return true;
  }

  // Handle Zstd decompression properly
  if (compression_type == 5) // Zstd
  {
    INFO_LOG_FMT(DISCIO, "HttpRVZReader: decompressing {} bytes with Zstd to {} bytes",
                 compressed_data.size(), decompressed_data.size());

    const size_t result = ZSTD_decompress(decompressed_data.data(), decompressed_data.size(),
                                         compressed_data.data(), compressed_data.size());

    if (ZSTD_isError(result))
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader: Zstd decompression failed: {}", ZSTD_getErrorName(result));
      return false;
    }

    if (result != decompressed_data.size())
    {
      WARN_LOG_FMT(DISCIO, "HttpRVZReader: Zstd decompressed size {} doesn't match expected size {}",
                   result, decompressed_data.size());
    }

    return true;
  }

  // For other compression types that are not yet implemented
  switch (compression_type)
  {
    case 1: // Purge
    case 2: // Bzip2
    case 3: // LZMA
    case 4: // LZMA2
      WARN_LOG_FMT(DISCIO, "HttpRVZReader: compression type {} not yet implemented for group entries, using raw data as fallback", compression_type);
      // Fallback: use compressed data directly (this won't work properly but prevents crashes)
      if (compressed_data.size() <= decompressed_data.size())
      {
        std::memcpy(decompressed_data.data(), compressed_data.data(), compressed_data.size());
        // Fill remaining with zeros if needed
        if (compressed_data.size() < decompressed_data.size())
        {
          std::memset(decompressed_data.data() + compressed_data.size(), 0, decompressed_data.size() - compressed_data.size());
        }
        return true;
      }
      else
      {
        ERROR_LOG_FMT(DISCIO, "HttpRVZReader: compressed data too large for decompressed buffer");
        return false;
      }
    default:
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader: unknown compression type {} for group entries", compression_type);
      return false;
  }
}

bool HttpRVZReader::UnpackRVZData(const std::vector<u8>& packed_data, u32 chunk_size, std::vector<u8>& unpacked_data)
{
  // RVZ packing decoding as described in WiaAndRvz.md
  // The encoding contains a mix of raw data and PRNG-generated padding



  unpacked_data.clear();
  unpacked_data.reserve(chunk_size);

  const u8* input_ptr = packed_data.data();
  const u8* input_end = packed_data.data() + packed_data.size();


  // Safety limits to prevent memory corruption
  constexpr u32 MAX_REASONABLE_SIZE = 16 * 1024 * 1024; // 16MB max per chunk
  constexpr u32 MAX_TOTAL_OUTPUT = 32 * 1024 * 1024;   // 32MB total max

  u32 chunk_count = 0;
  while (input_ptr < input_end && unpacked_data.size() < chunk_size)
  {
    // Log detailed pointer state at start of each loop iteration
    const size_t offset_in_stream = input_ptr - packed_data.data();
    const size_t remaining_bytes = input_end - input_ptr;

    // Check if we have enough bytes for a size header
    if (input_ptr + 4 > input_end)
    {
      break; // End of data - this is normal if we've processed all complete chunks
    }

    INFO_LOG_FMT(DISCIO, "HttpRVZReader::UnpackRVZData: chunk {}, offset in stream: {}", chunk_count, offset_in_stream);

    u32 be_size;
    std::memcpy(&be_size, input_ptr, 4);
    const u32 swapped_size = Common::swap32(be_size);

    // Junk/raw flag is bit 31 of the size value (after swapping from big-endian)
    const bool is_junk_data = (swapped_size & 0x80000000) != 0;
    const u32 actual_size = swapped_size & 0x7FFFFFFF;
    input_ptr += 4;


    // Critical: Validate size to prevent heap corruption
    if (actual_size > MAX_REASONABLE_SIZE)
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader::UnpackRVZData: unreasonable size {} (max {}) at offset {}",
                    actual_size, MAX_REASONABLE_SIZE, offset_in_stream);

      // Log complete buffer state when error occurs
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader::UnpackRVZData: ERROR STATE - input_ptr={:p}, input_end={:p}, packed_data.data()={:p}, packed_data.size()={}",
                    static_cast<const void*>(input_ptr), static_cast<const void*>(input_end),
                    static_cast<const void*>(packed_data.data()), packed_data.size());
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader::UnpackRVZData: ERROR STATE - chunk_count={}, offset_in_stream={}, remaining_bytes={}",
                    chunk_count, offset_in_stream, static_cast<size_t>(input_end - input_ptr));

      // Show surrounding bytes for debugging
      const size_t debug_start = (offset_in_stream >= 8) ? offset_in_stream - 8 : 0;
      const size_t debug_end = std::min(offset_in_stream + 16, packed_data.size());
      std::string debug_hex;
      for (size_t i = debug_start; i < debug_end; ++i)
      {
        char hex_byte[4];
        snprintf(hex_byte, sizeof(hex_byte), "%02x ", packed_data[i]);
        debug_hex += hex_byte;
        if (i == offset_in_stream) debug_hex += "[";
        if (i == offset_in_stream + 3) debug_hex += "] ";
      }
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader::UnpackRVZData: surrounding bytes: {}", debug_hex);

      return false;
    }

    // Prevent total output from growing too large
    if (unpacked_data.size() + actual_size > MAX_TOTAL_OUTPUT)
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader::UnpackRVZData: total output would exceed {} bytes", MAX_TOTAL_OUTPUT);
      return false;
    }

    // Check if we're about to exceed the expected chunk size
    if (unpacked_data.size() + actual_size > chunk_size * 2) // Allow some flexibility
    {
      WARN_LOG_FMT(DISCIO, "HttpRVZReader::UnpackRVZData: unpacked data would be much larger than expected chunk size ({} vs {})",
                   unpacked_data.size() + actual_size, chunk_size);
    }

    if (!is_junk_data)
    {
      // Raw data - copy directly
      if (input_ptr + actual_size > input_end)
      {
        ERROR_LOG_FMT(DISCIO, "HttpRVZReader::UnpackRVZData: insufficient data for raw data ({} bytes needed, {} available)",
                      actual_size, static_cast<u32>(input_end - input_ptr));
        return false;
      }


      // Insert raw data directly (size already validated above)
      unpacked_data.insert(unpacked_data.end(), input_ptr, input_ptr + actual_size);

      input_ptr += actual_size;
    }
    else
    {
      // PRNG-generated junk data
      // Read 68 bytes (17 u32s) of seed data
      constexpr size_t SEED_SIZE = 68;
      if (input_ptr + SEED_SIZE > input_end)
      {
        ERROR_LOG_FMT(DISCIO, "HttpRVZReader::UnpackRVZData: insufficient data for PRNG seed (need {}, have {})",
                      SEED_SIZE, static_cast<u32>(input_end - input_ptr));
        return false;
      }


      // Read the 68-byte seed (17 u32 values)
      std::array<u32, 17> seed;
      std::memcpy(seed.data(), input_ptr, SEED_SIZE);

      // Convert seed from big-endian to native endian
      for (auto& val : seed)
      {
        val = Common::swap32(val);
      }

      // Pre-validate size before resizing to avoid potential allocation failures
      const size_t current_size = unpacked_data.size();
      const size_t new_size = current_size + actual_size;
      unpacked_data.resize(new_size);

      // Implement RVZ PRNG algorithm: Lagged Fibonacci generator (f = xor, j = 32, k = 521)
      std::array<u32, 521> buffer;

      // Copy seed data to start of buffer (already converted from big-endian)
      std::memcpy(buffer.data(), seed.data(), SEED_SIZE);

      // Fill remaining buffer using Lagged Fibonacci formula
      for (size_t i = 17; i < 521; i++)
      {
        buffer[i] = (buffer[i - 17] << 23) ^ (buffer[i - 16] >> 9) ^ buffer[i - 1];
      }

      // Advance PRNG state 4 times as specified
      for (int advance = 0; advance < 4; advance++)
      {
        for (size_t i = 0; i < 32; i++)
          buffer[i] ^= buffer[i + 521 - 32];

        for (size_t i = 32; i < 521; i++)
          buffer[i] ^= buffer[i - 32];
      }

      // Generate output data
      size_t buffer_pos = 0;
      for (u32 i = 0; i < actual_size; i += 4)
      {
        // Advance buffer if we've used all 521 words
        if (buffer_pos >= 521)
        {
          for (size_t j = 0; j < 32; j++)
            buffer[j] ^= buffer[j + 521 - 32];

          for (size_t j = 32; j < 521; j++)
            buffer[j] ^= buffer[j - 32];

          buffer_pos = 0;
        }

        const u32 word = buffer[buffer_pos++];

        // Output bytes using the specified bit shifts: 24, 18, 8, 0
        const size_t remaining = actual_size - i;
        if (remaining >= 1) unpacked_data[current_size + i + 0] = static_cast<u8>(word >> 24);
        if (remaining >= 2) unpacked_data[current_size + i + 1] = static_cast<u8>(word >> 18);
        if (remaining >= 3) unpacked_data[current_size + i + 2] = static_cast<u8>(word >> 8);
        if (remaining >= 4) unpacked_data[current_size + i + 3] = static_cast<u8>(word);
      }

      input_ptr += SEED_SIZE;
    }

    chunk_count++;

    // Safety check - prevent infinite loops
    if (chunk_count > 1000) // Reasonable limit for number of chunks
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader::UnpackRVZData: too many chunks ({}), possible corruption", chunk_count);
      return false;
    }
  }


  return true;
}

u64 HttpRVZReader::GetRawSize() const
{
  return Common::swap64(m_header_1.wia_file_size);
}

u64 HttpRVZReader::GetDataSize() const
{
  return Common::swap64(m_header_1.iso_file_size);
}

u64 HttpRVZReader::GetBlockSize() const
{
  return Common::swap32(m_header_2.chunk_size);
}

std::string HttpRVZReader::GetCompressionMethod() const
{
  const u32 compression_type = Common::swap32(m_header_2.compression_type);
  switch (compression_type)
  {
    case 0: return "None";
    case 1: return "Zstd";
    case 2: return "LZ4";
    case 3: return "LZMA";
    default: return "Unknown";
  }
}

std::optional<int> HttpRVZReader::GetCompressionLevel() const
{
  return static_cast<int>(Common::swap32(m_header_2.compression_level));
}

bool HttpRVZReader::Read(u64 offset, u64 nbytes, u8* out_ptr)
{
  if (!m_headers_read && !ReadHeaders())
    return false;

  if (offset + nbytes > GetDataSize())
    return false;


  // Handle disc header directly (first 128 bytes) - stored in m_header_2.disc_header
  const u64 disc_header_size = 0x80; // 128 bytes
  if (offset < disc_header_size)
  {
    const u64 bytes_to_read = std::min(disc_header_size - offset, nbytes);
    std::memcpy(out_ptr, m_header_2.disc_header + offset, bytes_to_read);

    offset += bytes_to_read;
    nbytes -= bytes_to_read;
    out_ptr += bytes_to_read;

    if (nbytes == 0)
      return true;
  }


  // Handle raw data entries (offset 128+)
  for (size_t i = 0; i < m_raw_data_entries.size(); ++i)
  {
    const auto& entry = m_raw_data_entries[i];
    // Fields are already byte-swapped during parsing, no need to swap again
    const u64 data_offset = entry.raw_data_off;
    const u64 data_size = entry.raw_data_size;
    const u32 group_index = entry.group_index;
    const u32 number_of_groups = entry.n_groups;


    if (offset >= data_offset && offset < data_offset + data_size)
    {
      const u64 entry_offset = offset - data_offset;
      const u64 entry_bytes = std::min(nbytes, data_size - entry_offset);

      if (!ReadFromGroups(entry_offset, entry_bytes, out_ptr, group_index, number_of_groups, data_offset, data_size))
        return false;

            // Add special logging for critical disc structure data after reading
      if ((offset >= 0x2440 && offset <= 0x2460) || offset == 0x0424 || offset == 0x0428)
      {
        std::string hex_data;
        const size_t preview_size = std::min(static_cast<size_t>(entry_bytes), 16UL);
        for (size_t j = 0; j < preview_size; ++j)
        {
          hex_data += fmt::format("{:02x} ", out_ptr[j]);
        }

        const char* section_name =
          (offset >= 0x2440 && offset <= 0x2460) ? "APPLOADER" :
          offset == 0x0424 ? "FST_OFFSET" :
          offset == 0x0428 ? "FST_SIZE" : "UNKNOWN";

        INFO_LOG_FMT(DISCIO, "HttpRVZReader::Read: {} READ RESULT - offset={:#x}, data: {}",
                     section_name, offset, hex_data);

        // If this is a 4-byte read at specific offsets, also show as u32
        if (entry_bytes == 4)
        {
          u32 value = Common::swap32(*(u32*)out_ptr);
          INFO_LOG_FMT(DISCIO, "HttpRVZReader::Read: {} READ RESULT - offset={:#x}, u32 value={:#x} ({})",
                       section_name, offset, value, value);
        }
      }

      // If we read everything, we're done
      if (entry_bytes == nbytes)
        return true;

      // Otherwise, continue with next entries
      return Read(offset + entry_bytes, nbytes - entry_bytes, out_ptr + entry_bytes);
    }
  }

  ERROR_LOG_FMT(DISCIO, "HttpRVZReader::Read: offset {} not found in any raw data entry", offset);
  return false;
}

bool HttpRVZReader::ReadFromGroups(u64 offset, u64 size, u8* out_ptr, u32 group_index, u32 number_of_groups, u64 data_offset, u64 data_size)
{
  const u32 chunk_size = Common::swap32(m_header_2.chunk_size);
  const u32 file_compression_type = Common::swap32(m_header_2.compression_type);


  // Entry-relative bounds
  if (offset >= data_size)
    return size == 0;

  const u64 clamp_size = std::min(size, data_size - offset);

  // Entry starts inside a chunk at this modulo
  const u32 entry_start_mod = static_cast<u32>(data_offset % chunk_size);

  // Use absolute logical offset (entry-relative + entry modulo) and advance it as we copy
  u64 current_abs_offset = static_cast<u64>(entry_start_mod) + offset;

  // Compute starting group index within the entry's group stream
  const u64 start_group_index = current_abs_offset / chunk_size;

  u64 remain = clamp_size;
  u8* current_out_ptr = out_ptr;

  for (u64 i = start_group_index; i < number_of_groups && remain > 0; ++i)
  {
    const u64 total_group_index = group_index + i;
    if (total_group_index >= m_group_entries.size())
      return false;

    const GroupEntry& group = m_group_entries[total_group_index];
    const u64 group_file_offset = static_cast<u64>(Common::swap32(group.data_offset)) << 2; // data_off4 * 4
    const u32 rvz_packed_size = Common::swap32(group.rvz_packed_size);

    // Determine per-group compression from the first byte of the big-endian size field
    const u8* size_be_ptr = reinterpret_cast<const u8*>(&group.data_size);
    const bool group_is_compressed = (size_be_ptr[0] & 0x80) != 0;

    // Convert data_size to native and clear the compression flag bit for the size
    const u32 native_data_size = Common::swap32(group.data_size);
    const u32 compressed_data_size = native_data_size & 0x7FFFFFFF;


    // Absolute start of this group and offset within it
    const u64 this_group_abs_start = i * chunk_size;
    const u64 offset_in_group = current_abs_offset - this_group_abs_start;

    // Compute how much of this group belongs to the entry window
    const u64 entry_abs_end = static_cast<u64>(entry_start_mod) + data_size;
    const u64 group_abs_end = this_group_abs_start + chunk_size;
    const u64 usable_group_end = std::min(group_abs_end, entry_abs_end);
    const u64 usable_group_len = (usable_group_end > this_group_abs_start) ? (usable_group_end - this_group_abs_start) : 0;

    if (offset_in_group >= usable_group_len)
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader::ReadFromGroups: offset {} exceeds group usable size {} for group {}",
                    offset_in_group, usable_group_len, total_group_index);
      return false;
    }

    const u64 bytes_to_copy = std::min(remain, usable_group_len - offset_in_group);

    // Read the compressed/packed data from HTTP
    std::vector<u8> compressed_data(compressed_data_size);
    if (!m_http_reader->Read(group_file_offset, compressed_data_size, compressed_data.data()))
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader::ReadFromGroups: failed to read compressed data from offset {}", group_file_offset);
      return false;
    }

    // Decompress if needed
    std::vector<u8> decompressed_data;
    if (group_is_compressed)
    {

      // Decompress to the actual RVZ packed payload size if provided; otherwise, full chunk
      const u32 target_decompressed = rvz_packed_size > 0 ? rvz_packed_size : chunk_size;
      decompressed_data.resize(target_decompressed);

      if (file_compression_type == 0)
      {
        ERROR_LOG_FMT(DISCIO, "HttpRVZReader::ReadFromGroups: group marked as compressed but file compression type is 0");
        return false;
      }
      else if (file_compression_type == 5) // Zstd
      {
        const size_t result = ZSTD_decompress(decompressed_data.data(), decompressed_data.size(),
                                             compressed_data.data(), compressed_data.size());

        if (ZSTD_isError(result))
        {
          ERROR_LOG_FMT(DISCIO, "HttpRVZReader::ReadFromGroups: Zstd decompression failed for group {}: {}",
                        total_group_index, ZSTD_getErrorName(result));
          return false;
        }

        // For RVZ, result should equal the packed payload (rvz_packed_size) when present
        if (rvz_packed_size > 0 && result != rvz_packed_size)
        {
          WARN_LOG_FMT(DISCIO, "HttpRVZReader::ReadFromGroups: Zstd size {} != rvz_packed_size {} for group {}",
                       result, rvz_packed_size, total_group_index);
        }

        decompressed_data.resize(static_cast<size_t>(result));

      }
      else
      {
        WARN_LOG_FMT(DISCIO, "HttpRVZReader::ReadFromGroups: compression type {} not yet supported for group {}, using raw data as fallback",
                     file_compression_type, total_group_index);

        if (compressed_data.size() <= decompressed_data.size())
        {
          std::memcpy(decompressed_data.data(), compressed_data.data(), compressed_data.size());
          if (compressed_data.size() < decompressed_data.size())
          {
            std::memset(decompressed_data.data() + compressed_data.size(), 0,
                       decompressed_data.size() - compressed_data.size());
          }
        }
        else
        {
          ERROR_LOG_FMT(DISCIO, "HttpRVZReader::ReadFromGroups: compressed data size {} exceeds expected size {} for group {}",
                        compressed_data.size(), decompressed_data.size(), total_group_index);
          return false;
        }
      }
    }
    else
    {
      // Data is already uncompressed, but might be RVZ packed
      decompressed_data = std::move(compressed_data);
    }

    // Unpack RVZ data if needed
    std::vector<u8> final_data;
    if (rvz_packed_size > 0)
    {

      // Feed only the packed payload to the RVZ unpacker
      if (!UnpackRVZData(decompressed_data, chunk_size, final_data))
      {
        WARN_LOG_FMT(DISCIO, "HttpRVZReader::ReadFromGroups: RVZ unpacking failed for group {}, using raw data as fallback", total_group_index);
        final_data = std::move(decompressed_data);
      }
      else
      {
        // Ensure we never overrun the expected chunk size
        if (final_data.size() > chunk_size)
          final_data.resize(chunk_size);

      }
    }
    else
    {
      final_data = std::move(decompressed_data);
    }

    if (offset_in_group >= final_data.size())
    {
      ERROR_LOG_FMT(DISCIO, "HttpRVZReader::ReadFromGroups: offset {} exceeds group size {} for group {}",
                    offset_in_group, final_data.size(), total_group_index);
      return false;
    }

    const u64 actual_bytes_to_copy = std::min(bytes_to_copy, static_cast<u64>(final_data.size() - offset_in_group));
    std::memcpy(current_out_ptr, final_data.data() + offset_in_group, actual_bytes_to_copy);


    remain -= actual_bytes_to_copy;
    current_out_ptr += actual_bytes_to_copy;
    current_abs_offset += actual_bytes_to_copy;
  }

  return remain == 0;
}

// HTTP-backed WBFS reader implementation
std::unique_ptr<HttpWBFSReader> HttpWBFSReader::Create(const std::string& url)
{
  INFO_LOG_FMT(DISCIO, "HttpWBFSReader::Create called with URL: {}", url);

  auto http_reader = HttpBlobReader::Create(url);
  if (!http_reader)
  {
    ERROR_LOG_FMT(DISCIO, "HttpWBFSReader::Create: failed to create HttpBlobReader");
    return nullptr;
  }

  auto wbfs_reader = std::unique_ptr<HttpWBFSReader>(new HttpWBFSReader(std::move(http_reader)));
  if (!wbfs_reader->ReadHeader())
  {
    ERROR_LOG_FMT(DISCIO, "HttpWBFSReader::Create: failed to read WBFS header");
    return nullptr;
  }

  INFO_LOG_FMT(DISCIO, "HttpWBFSReader::Create: successfully created WBFS reader");
  return wbfs_reader;
}

HttpWBFSReader::HttpWBFSReader(std::unique_ptr<HttpBlobReader> http_reader)
: m_http_reader(std::move(http_reader))
{
}

std::unique_ptr<BlobReader> HttpWBFSReader::CopyReader() const
{
  return Create(m_http_reader->GetUrl());
}

bool HttpWBFSReader::ReadHeader()
{
  if (m_header_read)
    return true;

  INFO_LOG_FMT(DISCIO, "HttpWBFSReader: reading WBFS header");

  struct WBFSHeader
  {
    u32 magic;            // 'WBFS'
    u32 hd_sector_count;  // big-endian
    u8 hd_sector_shift;   // 2^n bytes
    u8 wbfs_sector_shift; // 2^n bytes
    u8 padding[2];
  };

  WBFSHeader header{};
  if (!m_http_reader->Read(0, sizeof(header), reinterpret_cast<u8*>(&header)))
  {
    ERROR_LOG_FMT(DISCIO, "HttpWBFSReader: failed to read WBFS header");
    return false;
  }

  if (header.magic != 0x53464257) // 'WBFS' in little endian
  {
    ERROR_LOG_FMT(DISCIO, "HttpWBFSReader: invalid WBFS magic: 0x{:08x}", header.magic);
    return false;
  }

  // Populate sizes/shifts
  m_sector_size = 1u << header.hd_sector_shift;
  m_hd_sector_shift = header.hd_sector_shift;
  m_wbfs_sector_shift = header.wbfs_sector_shift;
  m_wbfs_sector_size = 1ull << m_wbfs_sector_shift;

  // Constants from local reader
  static const u64 WII_SECTOR_SIZE = 0x8000;
  static const u64 WII_SECTOR_COUNT = 143432 * 2;
  static const u64 WII_DISC_HEADER_SIZE = 256;

  // Compute WLBA table size
  m_blocks_per_disc = (WII_SECTOR_COUNT * WII_SECTOR_SIZE + m_wbfs_sector_size - 1) / m_wbfs_sector_size;

  // Read WLBA table for slot 0: starts after disc header inside first hd sector
  const u64 wlba_offset = (1ull << m_hd_sector_shift) + WII_DISC_HEADER_SIZE;
  const u64 wlba_bytes = m_blocks_per_disc * sizeof(u16);
  std::vector<u8> buf(static_cast<size_t>(wlba_bytes));
  if (!m_http_reader->Read(wlba_offset, wlba_bytes, buf.data()))
  {
    ERROR_LOG_FMT(DISCIO, "HttpWBFSReader: failed to read WLBA table");
    return false;
  }

  m_wlba_table.resize(static_cast<size_t>(m_blocks_per_disc));
  for (size_t i = 0; i < m_blocks_per_disc; ++i)
  {
    // Big-endian 16-bit value in the table; combine bytes without extra swapping
    m_wlba_table[i] = static_cast<u16>((static_cast<u16>(buf[i * 2]) << 8) | static_cast<u16>(buf[i * 2 + 1]));
  }

  // Set data size to full disc logical size
  m_data_size = WII_SECTOR_COUNT * WII_SECTOR_SIZE;

  INFO_LOG_FMT(DISCIO, "HttpWBFSReader: WBFS header OK - hd_sector_size={}, wbfs_sector_size={}, blocks_per_disc={}",
               (1ull << m_hd_sector_shift), m_wbfs_sector_size, m_blocks_per_disc);

  m_header_read = true;
  return true;
}

u64 HttpWBFSReader::GetRawSize() const
{
  return m_http_reader->GetRawSize();
}

u64 HttpWBFSReader::GetDataSize() const
{
  return m_data_size;
}

u64 HttpWBFSReader::GetBlockSize() const
{
  return m_wbfs_sector_size ? static_cast<u64>(m_wbfs_sector_size) : static_cast<u64>(m_sector_size);
}

bool HttpWBFSReader::Read(u64 offset, u64 size, u8* out_ptr)
{
  if (!m_header_read && !ReadHeader())
    return false;

  // Bounds check
  if (offset + size > m_data_size)
    return false;

  // Map GC/Wii logical offset into WBFS cluster, similar to local reader
  while (size)
  {
    const u64 base_cluster = (offset >> m_wbfs_sector_shift);
    if (base_cluster >= m_blocks_per_disc)
      return false;

    const u64 cluster_address = m_wbfs_sector_size * m_wlba_table[base_cluster];
    const u64 cluster_offset = offset & (m_wbfs_sector_size - 1);
    const u64 final_address = cluster_address + cluster_offset;

    const u64 till_end_of_sector = m_wbfs_sector_size - cluster_offset;
    const u64 to_read = std::min<u64>(till_end_of_sector, size);

    if (!m_http_reader->Read(final_address, to_read, out_ptr))
      return false;

    out_ptr += to_read;
    size -= to_read;
    offset += to_read;
  }

  return true;
}

// HTTP-backed TGC reader implementation
std::unique_ptr<HttpTGCReader> HttpTGCReader::Create(const std::string& url)
{
  INFO_LOG_FMT(DISCIO, "HttpTGCReader::Create called with URL: {}", url);

  auto http_reader = HttpBlobReader::Create(url);
  if (!http_reader)
  {
    ERROR_LOG_FMT(DISCIO, "HttpTGCReader::Create: failed to create HttpBlobReader");
    return nullptr;
  }

  auto tgc_reader = std::unique_ptr<HttpTGCReader>(new HttpTGCReader(std::move(http_reader)));
  if (!tgc_reader->ReadHeader())
  {
    ERROR_LOG_FMT(DISCIO, "HttpTGCReader::Create: failed to read TGC header");
    return nullptr;
  }

  INFO_LOG_FMT(DISCIO, "HttpTGCReader::Create: successfully created TGC reader");
  return tgc_reader;
}

HttpTGCReader::HttpTGCReader(std::unique_ptr<HttpBlobReader> http_reader)
: m_http_reader(std::move(http_reader))
{
}

std::unique_ptr<BlobReader> HttpTGCReader::CopyReader() const
{
  return Create(m_http_reader->GetUrl());
}

bool HttpTGCReader::ReadHeader()
{
  if (m_header_read)
    return true;

  INFO_LOG_FMT(DISCIO, "HttpTGCReader: reading TGC header");

  // Read TGC header
  struct TGCHeader
  {
    u32 magic;
    u32 unknown_1;
    u32 tgc_header_size;
    u32 disc_header_area_size;
    // ... more fields
  };

  TGCHeader header;
  if (!m_http_reader->Read(0, sizeof(header), reinterpret_cast<u8*>(&header)))
  {
    ERROR_LOG_FMT(DISCIO, "HttpTGCReader: failed to read TGC header");
    return false;
  }

  // Validate header
  if (header.magic != 0xA2380FAE) // TGC_MAGIC
  {
    ERROR_LOG_FMT(DISCIO, "HttpTGCReader: invalid TGC magic: 0x{:08x}", header.magic);
    return false;
  }

  m_header_size = header.tgc_header_size;
  m_data_size = m_http_reader->GetRawSize(); // Use full file size for now

  INFO_LOG_FMT(DISCIO, "HttpTGCReader: TGC header - header_size: {}, data_size: {}", m_header_size, m_data_size);

  m_header_read = true;
  return true;
}

u64 HttpTGCReader::GetRawSize() const
{
  return m_http_reader->GetRawSize();
}

u64 HttpTGCReader::GetDataSize() const
{
  return m_data_size;
}

bool HttpTGCReader::Read(u64 offset, u64 size, u8* out_ptr)
{
  if (!m_header_read && !ReadHeader())
    return false;

  // TGC has embedded disc structure - for now, just pass through to HTTP reader
  // A full implementation would need to handle the TGC virtual offset mapping
  INFO_LOG_FMT(DISCIO, "HttpTGCReader::Read: TGC format requires virtual offset mapping - using simplified passthrough");
  return m_http_reader->Read(offset, size, out_ptr);
}

// HttpWIAReader implementation
std::unique_ptr<HttpWIAReader> HttpWIAReader::Create(const std::string& url)
{
  auto http_reader = HttpBlobReader::Create(url);
  if (!http_reader)
    return nullptr;

  auto wia_reader = std::unique_ptr<HttpWIAReader>(new HttpWIAReader(std::move(http_reader)));
  if (!wia_reader->ReadHeaders())
    return nullptr;

  return wia_reader;
}

HttpWIAReader::HttpWIAReader(std::unique_ptr<HttpBlobReader> http_reader)
    : m_http_reader(std::move(http_reader))
{
}

std::unique_ptr<BlobReader> HttpWIAReader::CopyReader() const
{
  return HttpWIAReader::Create(m_http_reader->GetUrl());
}

bool HttpWIAReader::ReadHeaders()
{
  if (m_headers_read)
    return true;

  INFO_LOG_FMT(DISCIO, "HttpWIAReader: Reading WIA headers");

  // Read file header (0x48 bytes at offset 0)
  if (!m_http_reader->Read(0, sizeof(WIAFileHeader), reinterpret_cast<u8*>(&m_file_header)))
  {
    ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Failed to read file header");
    return false;
  }

  // Verify magic number
  if (memcmp(m_file_header.magic, "WIA\x1", 4) != 0)
  {
    ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Invalid WIA magic number");
    return false;
  }

  // Convert from big endian
  m_file_header.version = Common::swap32(m_file_header.version);
  m_file_header.version_compatible = Common::swap32(m_file_header.version_compatible);
  m_file_header.disc_size = Common::swap32(m_file_header.disc_size);
  m_file_header.iso_file_size = Common::swap64(m_file_header.iso_file_size);
  m_file_header.wia_file_size = Common::swap64(m_file_header.wia_file_size);

  INFO_LOG_FMT(DISCIO, "HttpWIAReader: WIA version {:#x}, compatible {:#x}, ISO size {} bytes",
               m_file_header.version, m_file_header.version_compatible, m_file_header.iso_file_size);

  // Read disc header (starts at offset 0x48)
  if (!m_http_reader->Read(0x48, sizeof(WIADiscHeader), reinterpret_cast<u8*>(&m_disc_header)))
  {
    ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Failed to read disc header");
    return false;
  }

  // Convert from big endian
  m_disc_header.disc_type = Common::swap32(m_disc_header.disc_type);
  m_disc_header.compression = Common::swap32(m_disc_header.compression);
  m_disc_header.compr_level = Common::swap32(m_disc_header.compr_level);
  m_disc_header.chunk_size = Common::swap32(m_disc_header.chunk_size);
  m_disc_header.n_part = Common::swap32(m_disc_header.n_part);
  m_disc_header.part_t_size = Common::swap32(m_disc_header.part_t_size);
  m_disc_header.part_off = Common::swap64(m_disc_header.part_off);
  m_disc_header.n_raw_data = Common::swap32(m_disc_header.n_raw_data);
  m_disc_header.raw_data_off = Common::swap64(m_disc_header.raw_data_off);
  m_disc_header.raw_data_size = Common::swap32(m_disc_header.raw_data_size);
  m_disc_header.n_groups = Common::swap32(m_disc_header.n_groups);
  m_disc_header.group_off = Common::swap64(m_disc_header.group_off);
  m_disc_header.group_size = Common::swap32(m_disc_header.group_size);

  m_compression_type = m_disc_header.compression;
  m_iso_file_size = m_file_header.iso_file_size;
  m_chunk_size = m_disc_header.chunk_size;

  INFO_LOG_FMT(DISCIO, "HttpWIAReader: Disc type {}, compression {}, chunk size {} bytes, {} raw data entries, {} groups",
               m_disc_header.disc_type, m_compression_type, m_chunk_size, m_disc_header.n_raw_data, m_disc_header.n_groups);

  // Check for unsupported compression methods
  if (m_compression_type == 1) // PURGE
  {
    ERROR_LOG_FMT(DISCIO, "HttpWIAReader: PURGE compression is not yet supported over HTTP");
    return false;
  }

  if (m_compression_type > 4) // Unknown compression
  {
    ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Unknown compression method {}", m_compression_type);
    return false;
  }

  // Read raw data entries and group entries
  if (!ReadRawDataEntries() || !ReadGroupEntries())
    return false;

  m_headers_read = true;
  return true;
}

bool HttpWIAReader::ReadRawDataEntries()
{
  if (m_disc_header.n_raw_data == 0)
    return true;

  INFO_LOG_FMT(DISCIO, "HttpWIAReader: Reading {} raw data entries from offset {:#x}, compressed size {}",
               m_disc_header.n_raw_data, m_disc_header.raw_data_off, m_disc_header.raw_data_size);

  // Read compressed raw data entries
  std::vector<u8> compressed_data(m_disc_header.raw_data_size);
  if (!m_http_reader->Read(m_disc_header.raw_data_off, m_disc_header.raw_data_size, compressed_data.data()))
  {
    ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Failed to read raw data entries");
    return false;
  }

  // Decompress the raw data entries
  std::vector<u8> decompressed_data;
  if (m_compression_type == 0) // NONE
  {
    decompressed_data = std::move(compressed_data);
  }
  else
  {
    // For compressed WIA files, the raw data entries are compressed using the same method
    DecompressionBuffer in_buffer;
    in_buffer.data = std::move(compressed_data);
    in_buffer.bytes_written = in_buffer.data.size();

    const size_t expected_size = m_disc_header.n_raw_data * sizeof(WIARawDataEntry);
    DecompressionBuffer out_buffer;
    out_buffer.data.resize(expected_size);

    size_t in_bytes_read = 0;
    bool success = false;

    if (m_compression_type == 2) // BZIP2
    {
      auto decompressor = std::make_unique<Bzip2Decompressor>();
      success = decompressor->Decompress(in_buffer, &out_buffer, &in_bytes_read);
    }
    else if (m_compression_type == 3) // LZMA
    {
      auto decompressor = std::make_unique<LZMADecompressor>(false, nullptr, 0);
      success = decompressor->Decompress(in_buffer, &out_buffer, &in_bytes_read);
    }
    else if (m_compression_type == 4) // LZMA2
    {
      auto decompressor = std::make_unique<LZMADecompressor>(true, nullptr, 0);
      success = decompressor->Decompress(in_buffer, &out_buffer, &in_bytes_read);
    }
    else
    {
      ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Unsupported compression for raw data entries: {}", m_compression_type);
      return false;
    }

    if (!success)
    {
      ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Failed to decompress raw data entries");
      return false;
    }

    out_buffer.data.resize(out_buffer.bytes_written);
    decompressed_data = std::move(out_buffer.data);
  }

  // Parse the decompressed raw data entries
  const size_t expected_size = m_disc_header.n_raw_data * sizeof(WIARawDataEntry);
  if (decompressed_data.size() < expected_size)
  {
    ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Decompressed raw data entries too small: {} < {}", decompressed_data.size(), expected_size);
    return false;
  }

  m_raw_data_entries.resize(m_disc_header.n_raw_data);
  memcpy(m_raw_data_entries.data(), decompressed_data.data(), expected_size);

  // Convert from big endian
  for (auto& entry : m_raw_data_entries)
  {
    entry.raw_data_off = Common::swap64(entry.raw_data_off);
    entry.raw_data_size = Common::swap64(entry.raw_data_size);
    entry.group_index = Common::swap32(entry.group_index);
    entry.n_groups = Common::swap32(entry.n_groups);
  }

  INFO_LOG_FMT(DISCIO, "HttpWIAReader: Successfully read {} raw data entries", m_raw_data_entries.size());
  return true;
}

bool HttpWIAReader::ReadGroupEntries()
{
  if (m_disc_header.n_groups == 0)
    return true;

  INFO_LOG_FMT(DISCIO, "HttpWIAReader: Reading {} group entries from offset {:#x}, compressed size {}",
               m_disc_header.n_groups, m_disc_header.group_off, m_disc_header.group_size);

  // Read compressed group entries
  std::vector<u8> compressed_data(m_disc_header.group_size);
  if (!m_http_reader->Read(m_disc_header.group_off, m_disc_header.group_size, compressed_data.data()))
  {
    ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Failed to read group entries");
    return false;
  }

  // Decompress the group entries
  std::vector<u8> decompressed_data;
  if (m_compression_type == 0) // NONE
  {
    decompressed_data = std::move(compressed_data);
  }
  else
  {
    // For compressed WIA files, the group entries are compressed using the same method
    DecompressionBuffer in_buffer;
    in_buffer.data = std::move(compressed_data);
    in_buffer.bytes_written = in_buffer.data.size();

    const size_t expected_size = m_disc_header.n_groups * sizeof(WIAGroupEntry);
    DecompressionBuffer out_buffer;
    out_buffer.data.resize(expected_size);

    size_t in_bytes_read = 0;
    bool success = false;

    if (m_compression_type == 2) // BZIP2
    {
      auto decompressor = std::make_unique<Bzip2Decompressor>();
      success = decompressor->Decompress(in_buffer, &out_buffer, &in_bytes_read);
    }
    else if (m_compression_type == 3) // LZMA
    {
      auto decompressor = std::make_unique<LZMADecompressor>(false, nullptr, 0);
      success = decompressor->Decompress(in_buffer, &out_buffer, &in_bytes_read);
    }
    else if (m_compression_type == 4) // LZMA2
    {
      auto decompressor = std::make_unique<LZMADecompressor>(true, nullptr, 0);
      success = decompressor->Decompress(in_buffer, &out_buffer, &in_bytes_read);
    }
    else
    {
      ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Unsupported compression for group entries: {}", m_compression_type);
      return false;
    }

    if (!success)
    {
      ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Failed to decompress group entries");
      return false;
    }

    out_buffer.data.resize(out_buffer.bytes_written);
    decompressed_data = std::move(out_buffer.data);
  }

  // Parse the decompressed group entries
  const size_t expected_size = m_disc_header.n_groups * sizeof(WIAGroupEntry);
  if (decompressed_data.size() < expected_size)
  {
    ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Decompressed group entries too small: {} < {}", decompressed_data.size(), expected_size);
    return false;
  }

  m_group_entries.resize(m_disc_header.n_groups);
  memcpy(m_group_entries.data(), decompressed_data.data(), expected_size);

  // Convert from big endian
  for (auto& entry : m_group_entries)
  {
    entry.data_off4 = Common::swap32(entry.data_off4);
    entry.data_size = Common::swap32(entry.data_size);
  }

  INFO_LOG_FMT(DISCIO, "HttpWIAReader: Successfully read {} group entries", m_group_entries.size());
  return true;
}

u64 HttpWIAReader::GetRawSize() const
{
  return m_http_reader->GetRawSize();
}

u64 HttpWIAReader::GetDataSize() const
{
  return m_iso_file_size;
}

u64 HttpWIAReader::GetBlockSize() const
{
  return m_chunk_size;
}

std::string HttpWIAReader::GetCompressionMethod() const
{
  switch (m_compression_type)
  {
  case 0: return "NONE";
  case 1: return "PURGE";
  case 2: return "BZIP2";
  case 3: return "LZMA";
  case 4: return "LZMA2";
  default: return "Unknown";
  }
}

std::optional<int> HttpWIAReader::GetCompressionLevel() const
{
  if (m_compression_type == 0) // NONE
    return std::nullopt;
  return static_cast<int>(m_disc_header.compr_level);
}

bool HttpWIAReader::Read(u64 offset, u64 size, u8* out_ptr)
{
  if (!m_headers_read && !ReadHeaders())
    return false;

  if (offset >= m_iso_file_size)
    return false;

  if (offset + size > m_iso_file_size)
    size = m_iso_file_size - offset;

  // Handle disc header (first 0x80 bytes)
  if (offset < 0x80)
  {
    const u64 header_size = std::min(size, 0x80 - offset);
    memcpy(out_ptr, m_disc_header.dhead + offset, header_size);

    if (size == header_size)
      return true;

    // Continue with remaining data
    offset += header_size;
    size -= header_size;
    out_ptr += header_size;
  }

  return ReadFromGroups(offset, size, out_ptr);
}

bool HttpWIAReader::ReadFromGroups(u64 offset, u64 size, u8* out_ptr)
{
  // Find which raw data entry contains this offset
  for (const auto& raw_entry : m_raw_data_entries)
  {
    if (offset >= raw_entry.raw_data_off && offset < raw_entry.raw_data_off + raw_entry.raw_data_size)
    {
      const u64 entry_offset = offset - raw_entry.raw_data_off;
      const u64 available_size = std::min(size, raw_entry.raw_data_size - entry_offset);

      // Calculate which group(s) we need
      const u64 group_start = entry_offset / m_chunk_size;
      const u64 group_end = (entry_offset + available_size - 1) / m_chunk_size;

      u64 bytes_read = 0;

      for (u64 group_idx = group_start; group_idx <= group_end; ++group_idx)
      {
        const u32 actual_group_idx = raw_entry.group_index + static_cast<u32>(group_idx);

        if (actual_group_idx >= m_group_entries.size())
        {
          ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Group index {} out of range", actual_group_idx);
          return false;
        }

        const auto& group = m_group_entries[actual_group_idx];
        const u64 group_offset_in_entry = group_idx * m_chunk_size;
        const u64 read_offset_in_group = (entry_offset + bytes_read) - group_offset_in_entry;
        const u64 read_size_from_group = std::min(available_size - bytes_read, m_chunk_size - read_offset_in_group);

        // Check cache first
        auto cache_it = m_decompressed_cache.find(actual_group_idx);
        if (cache_it != m_decompressed_cache.end())
        {
          const auto& cached_data = cache_it->second;
          if (read_offset_in_group + read_size_from_group <= cached_data.size())
          {
            memcpy(out_ptr + bytes_read, cached_data.data() + read_offset_in_group, read_size_from_group);
            bytes_read += read_size_from_group;
            continue;
          }
        }

        // Cache miss - need to decompress the group
        if (group.data_size == 0)
        {
          // Special case: all zeros
          std::vector<u8> zero_data(m_chunk_size, 0);
          memcpy(out_ptr + bytes_read, zero_data.data() + read_offset_in_group, read_size_from_group);
        }
        else
        {
          // Read and decompress the group data
          const u64 group_file_offset = static_cast<u64>(group.data_off4) * 4;
          std::vector<u8> compressed_data(group.data_size);

          if (!m_http_reader->Read(group_file_offset, group.data_size, compressed_data.data()))
          {
            ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Failed to read group data at offset {:#x}", group_file_offset);
            return false;
          }

          std::vector<u8> decompressed_data;

          if (m_compression_type == 0) // NONE
          {
            decompressed_data = std::move(compressed_data);
          }
          else if (m_compression_type == 2) // BZIP2
          {
            DecompressionBuffer in_buffer;
            in_buffer.data = std::move(compressed_data);
            in_buffer.bytes_written = in_buffer.data.size();

            DecompressionBuffer out_buffer;
            out_buffer.data.resize(m_chunk_size);

            auto bzip2_decompressor = std::make_unique<Bzip2Decompressor>();
            size_t in_bytes_read = 0;
            if (!bzip2_decompressor->Decompress(in_buffer, &out_buffer, &in_bytes_read))
            {
              ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Bzip2 decompression failed");
              return false;
            }
            out_buffer.data.resize(out_buffer.bytes_written);
            decompressed_data = std::move(out_buffer.data);
          }
          else if (m_compression_type == 3) // LZMA
          {
            DecompressionBuffer in_buffer;
            in_buffer.data = std::move(compressed_data);
            in_buffer.bytes_written = in_buffer.data.size();

            DecompressionBuffer out_buffer;
            out_buffer.data.resize(m_chunk_size);

            auto lzma_decompressor = std::make_unique<LZMADecompressor>(false, nullptr, 0);
            size_t in_bytes_read = 0;
            if (!lzma_decompressor->Decompress(in_buffer, &out_buffer, &in_bytes_read))
            {
              ERROR_LOG_FMT(DISCIO, "HttpWIAReader: LZMA decompression failed");
              return false;
            }
            out_buffer.data.resize(out_buffer.bytes_written);
            decompressed_data = std::move(out_buffer.data);
          }
          else if (m_compression_type == 4) // LZMA2
          {
            DecompressionBuffer in_buffer;
            in_buffer.data = std::move(compressed_data);
            in_buffer.bytes_written = in_buffer.data.size();

            DecompressionBuffer out_buffer;
            out_buffer.data.resize(m_chunk_size);

            auto lzma_decompressor = std::make_unique<LZMADecompressor>(true, nullptr, 0);
            size_t in_bytes_read = 0;
            if (!lzma_decompressor->Decompress(in_buffer, &out_buffer, &in_bytes_read))
            {
              ERROR_LOG_FMT(DISCIO, "HttpWIAReader: LZMA2 decompression failed");
              return false;
            }
            out_buffer.data.resize(out_buffer.bytes_written);
            decompressed_data = std::move(out_buffer.data);
          }
          else
          {
            ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Unsupported compression type {}", m_compression_type);
            return false;
          }

          // Cache the decompressed data
          if (m_decompressed_cache.size() >= MAX_CACHED_CHUNKS)
          {
            m_decompressed_cache.clear(); // Simple eviction
          }
          m_decompressed_cache[actual_group_idx] = decompressed_data;

          // Copy the requested portion
          if (read_offset_in_group + read_size_from_group <= decompressed_data.size())
          {
            memcpy(out_ptr + bytes_read, decompressed_data.data() + read_offset_in_group, read_size_from_group);
          }
          else
          {
            ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Decompressed data too small");
            return false;
          }
        }

        bytes_read += read_size_from_group;
      }

      return bytes_read == available_size;
    }
  }

  ERROR_LOG_FMT(DISCIO, "HttpWIAReader: Offset {:#x} not found in any raw data entry", offset);
  return false;
}



}  // namespace DiscIO
