// Copyright 2017 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/HttpRequest.h"

#include <chrono>
#include <cstddef>
#include <cstdlib>
#include <mutex>

#include <curl/curl.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IOS || TARGET_OS_TV
#include <CoreFoundation/CoreFoundation.h>
#include <CFNetwork/CFNetwork.h>
#endif
#endif

#if !defined(_WIN32)
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#endif

#include "Common/CommonPaths.h"
#include "Common/FileUtil.h"
#include "Common/Logging/Log.h"
#include "Common/ScopeGuard.h"
#include "Common/StringUtil.h"

namespace Common
{
class HttpRequest::Impl final
{
public:
  enum class Method
  {
    GET,
    POST,
  };

  explicit Impl(std::chrono::milliseconds timeout_ms, ProgressCallback callback);

  bool IsValid() const;
  std::string GetHeaderValue(std::string_view name) const;
  void SetCookies(const std::string& cookies);
  void UseIPv4();
  void FollowRedirects(long max);
  s32 GetLastResponseCode();
  Response Fetch(const std::string& url, Method method, const Headers& headers, const u8* payload,
                 size_t size, AllowedReturnCodes codes = AllowedReturnCodes::Ok_Only,
                 std::span<Multiform> multiform = {});

  static int CurlProgressCallback(Impl* impl, curl_off_t dltotal, curl_off_t dlnow,
                                  curl_off_t ultotal, curl_off_t ulnow);
  std::string EscapeComponent(const std::string& string);

private:
  // iOS curl threaded-resolver workaround: pre-resolve the host via the system
  // resolver and feed the result to curl through CURLOPT_RESOLVE. Internal only;
  // not exposed on the public HttpRequest interface.
  void PreResolveHost(const std::string& host, int port);

  static inline std::once_flag s_curl_was_initialized;
  ProgressCallback m_callback;
  Headers m_response_headers;
  std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> m_curl{nullptr, curl_easy_cleanup};
  std::string m_error_string;
  std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> m_resolve{nullptr,
                                                                        curl_slist_free_all};
};

HttpRequest::HttpRequest(std::chrono::milliseconds timeout_ms, ProgressCallback callback)
    : m_impl(std::make_unique<Impl>(timeout_ms, std::move(callback)))
{
}

HttpRequest::~HttpRequest() = default;

bool HttpRequest::IsValid() const
{
  return m_impl->IsValid();
}

void HttpRequest::SetCookies(const std::string& cookies)
{
  m_impl->SetCookies(cookies);
}

void HttpRequest::UseIPv4()
{
  m_impl->UseIPv4();
}

void HttpRequest::FollowRedirects(long max)
{
  m_impl->FollowRedirects(max);
}

std::string HttpRequest::EscapeComponent(const std::string& string)
{
  return m_impl->EscapeComponent(string);
}

s32 HttpRequest::GetLastResponseCode() const
{
  return m_impl->GetLastResponseCode();
}

std::string HttpRequest::GetHeaderValue(std::string_view name) const
{
  return m_impl->GetHeaderValue(name);
}

HttpRequest::Response HttpRequest::Get(const std::string& url, const Headers& headers,
                                       AllowedReturnCodes codes)
{
  return m_impl->Fetch(url, Impl::Method::GET, headers, nullptr, 0, codes);
}

HttpRequest::Response HttpRequest::Post(const std::string& url, const std::vector<u8>& payload,
                                        const Headers& headers, AllowedReturnCodes codes)
{
  return m_impl->Fetch(url, Impl::Method::POST, headers, payload.data(), payload.size(), codes);
}

HttpRequest::Response HttpRequest::Post(const std::string& url, const std::string& payload,
                                        const Headers& headers, AllowedReturnCodes codes)
{
  return m_impl->Fetch(url, Impl::Method::POST, headers,
                       reinterpret_cast<const u8*>(payload.data()), payload.size(), codes);
}

int HttpRequest::Impl::CurlProgressCallback(Impl* impl, curl_off_t dltotal, curl_off_t dlnow,
                                            curl_off_t ultotal, curl_off_t ulnow)
{
  // Abort if callback isn't true
  return !impl->m_callback(static_cast<s64>(dltotal), static_cast<s64>(dlnow),
                           static_cast<s64>(ultotal), static_cast<s64>(ulnow));
}

HttpRequest::Impl::Impl(std::chrono::milliseconds timeout_ms, ProgressCallback callback)
    : m_callback(std::move(callback))
{
  std::call_once(s_curl_was_initialized, [] { curl_global_init(CURL_GLOBAL_DEFAULT); });

  m_curl.reset(curl_easy_init());
  if (!m_curl)
    return;

  curl_easy_setopt(m_curl.get(), CURLOPT_NOPROGRESS, m_callback == nullptr);

  if (m_callback)
  {
    curl_easy_setopt(m_curl.get(), CURLOPT_PROGRESSDATA, this);
    curl_easy_setopt(m_curl.get(), CURLOPT_XFERINFOFUNCTION, CurlProgressCallback);
  }

  // Set up error buffer
  m_error_string.resize(CURL_ERROR_SIZE);
  curl_easy_setopt(m_curl.get(), CURLOPT_ERRORBUFFER, m_error_string.data());

  // libcurl may not have been built with async DNS support, so we disable
  // signal handlers to avoid a possible and likely crash if a resolve times out.
  curl_easy_setopt(m_curl.get(), CURLOPT_NOSIGNAL, true);
  curl_easy_setopt(m_curl.get(), CURLOPT_CONNECTTIMEOUT_MS, static_cast<long>(timeout_ms.count()));
  // Sadly CURLOPT_LOW_SPEED_TIME doesn't have a millisecond variant so we have to use seconds
  curl_easy_setopt(
      m_curl.get(), CURLOPT_LOW_SPEED_TIME,
      static_cast<long>(std::chrono::duration_cast<std::chrono::seconds>(timeout_ms).count()));
  curl_easy_setopt(m_curl.get(), CURLOPT_LOW_SPEED_LIMIT, 1);
#ifdef IPHONEOS
  curl_easy_setopt(m_curl.get(), CURLOPT_CAINFO, (File::GetBundleDirectory() + DIR_SEP + "cacert.pem").c_str());
#endif
}

bool HttpRequest::Impl::IsValid() const
{
  return m_curl != nullptr;
}

s32 HttpRequest::Impl::GetLastResponseCode()
{
  long response_code{};
  curl_easy_getinfo(m_curl.get(), CURLINFO_RESPONSE_CODE, &response_code);
  return static_cast<s32>(response_code);
}

void HttpRequest::Impl::SetCookies(const std::string& cookies)
{
  curl_easy_setopt(m_curl.get(), CURLOPT_COOKIE, cookies.c_str());
}

void HttpRequest::Impl::UseIPv4()
{
  curl_easy_setopt(m_curl.get(), CURLOPT_IPRESOLVE, CURL_IPRESOLVE_V4);
}

HttpRequest::Response HttpRequest::PostMultiform(const std::string& url,
                                                 std::span<Multiform> multiform,
                                                 const Headers& headers, AllowedReturnCodes codes)
{
  return m_impl->Fetch(url, Impl::Method::POST, headers, nullptr, 0, codes, multiform);
}

void HttpRequest::Impl::FollowRedirects(long max)
{
  curl_easy_setopt(m_curl.get(), CURLOPT_FOLLOWLOCATION, 1);
  curl_easy_setopt(m_curl.get(), CURLOPT_MAXREDIRS, max);
}

void HttpRequest::Impl::PreResolveHost(const std::string& host, int port)
{
#if !defined(_WIN32)
  // Attempt to resolve host via system and provide hint to curl
  addrinfo hints{};
  hints.ai_family = AF_UNSPEC; // IPv4 or IPv6
  hints.ai_socktype = SOCK_STREAM;
  addrinfo* res = nullptr;
  const std::string port_str = std::to_string(port);
  if (getaddrinfo(host.c_str(), port_str.c_str(), &hints, &res) == 0 && res)
  {
    for (addrinfo* ai = res; ai != nullptr; ai = ai->ai_next)
    {
      char ipbuf[INET6_ADDRSTRLEN] = {0};
      std::string ip;
      if (ai->ai_family == AF_INET)
      {
        auto* a = reinterpret_cast<sockaddr_in*>(ai->ai_addr);
        inet_ntop(AF_INET, &a->sin_addr, ipbuf, sizeof(ipbuf));
        ip.assign(ipbuf);
      }
      else if (ai->ai_family == AF_INET6)
      {
        auto* a6 = reinterpret_cast<sockaddr_in6*>(ai->ai_addr);
        inet_ntop(AF_INET6, &a6->sin6_addr, ipbuf, sizeof(ipbuf));
        ip.assign(ipbuf);
      }
      if (!ip.empty())
      {
        // If IPv6, bracket the literal as required by CURLOPT_RESOLVE and skip if libcurl has no IPv6
        bool is_ipv6 = ip.find(':') != std::string::npos;
        if (is_ipv6)
        {
          const curl_version_info_data* vi = curl_version_info(CURLVERSION_NOW);
          if (!(vi && (vi->features & CURL_VERSION_IPV6)))
          {
            // libcurl built without IPv6 support; skip this entry
            continue;
          }
        }
        const std::string ip_literal = is_ipv6 ? ("[" + ip + "]") : ip;
        std::string entry = host + ":" + port_str + ":" + ip_literal;
        curl_slist* raw = m_resolve.release();
        raw = curl_slist_append(raw, entry.c_str());
        m_resolve.reset(raw);
        fprintf(stderr, "[HTTP] PreResolved %s:%s -> %s\n", host.c_str(), port_str.c_str(), ip.c_str());
      }
    }
    curl_easy_setopt(m_curl.get(), CURLOPT_RESOLVE, m_resolve.get());
    freeaddrinfo(res);
  }
#else
  (void)host; (void)port;
#endif
}

std::string HttpRequest::Impl::GetHeaderValue(std::string_view name) const
{
  for (const auto& [key, value] : m_response_headers)
  {
    if (key == name)
      return value.value();
  }

  return {};
}

std::string HttpRequest::Impl::EscapeComponent(const std::string& string)
{
  char* escaped = curl_easy_escape(m_curl.get(), string.c_str(), static_cast<int>(string.size()));
  std::string escaped_str(escaped);
  curl_free(escaped);

  return escaped_str;
}

static size_t CurlWriteCallback(char* data, size_t size, size_t nmemb, void* userdata)
{
  auto* buffer = static_cast<std::vector<u8>*>(userdata);
  const size_t actual_size = size * nmemb;
  buffer->insert(buffer->end(), data, data + actual_size);
  return actual_size;
}

static size_t header_callback(char* buffer, size_t size, size_t nitems, void* userdata)
{
  auto* headers = static_cast<HttpRequest::Headers*>(userdata);
  std::string_view full_buffer = std::string_view{buffer, nitems};
  const size_t colon_pos = full_buffer.find(':');
  if (colon_pos == std::string::npos)
    return nitems * size;

  const std::string_view key = full_buffer.substr(0, colon_pos);
  const std::string_view value = StripWhitespace(full_buffer.substr(colon_pos + 1));

  headers->emplace(std::string{key}, std::string{value});
  return nitems * size;
}

HttpRequest::Response HttpRequest::Impl::Fetch(const std::string& url, Method method,
                                               const Headers& headers, const u8* payload,
                                               size_t size, AllowedReturnCodes codes,
                                               std::span<Multiform> multiform)
{
  m_response_headers.clear();
  curl_easy_setopt(m_curl.get(), CURLOPT_POST, method == Method::POST);
  curl_easy_setopt(m_curl.get(), CURLOPT_URL, url.c_str());
  if (method == Method::POST && multiform.empty())
  {
    curl_easy_setopt(m_curl.get(), CURLOPT_POSTFIELDS, payload);
    curl_easy_setopt(m_curl.get(), CURLOPT_POSTFIELDSIZE, size);
  }

  curl_mime* form = nullptr;
  Common::ScopeGuard multiform_guard{[&form] { curl_mime_free(form); }};
  if (!multiform.empty())
  {
    form = curl_mime_init(m_curl.get());
    for (const auto& value : multiform)
    {
      curl_mimepart* part = curl_mime_addpart(form);
      curl_mime_name(part, value.name.c_str());
      curl_mime_data(part, value.data.c_str(), value.data.size());
    }

    curl_easy_setopt(m_curl.get(), CURLOPT_MIMEPOST, form);
  }

  curl_slist* list = nullptr;
  Common::ScopeGuard list_guard{[&list] { curl_slist_free_all(list); }};
  for (const auto& [name, value] : headers)
  {
    if (!value)
      list = curl_slist_append(list, (name + ':').c_str());
    else if (value->empty())
      list = curl_slist_append(list, (name + ';').c_str());
    else
      list = curl_slist_append(list, (name + ": " + *value).c_str());
  }
  curl_easy_setopt(m_curl.get(), CURLOPT_HTTPHEADER, list);

  curl_easy_setopt(m_curl.get(), CURLOPT_HEADERFUNCTION, header_callback);
  curl_easy_setopt(m_curl.get(), CURLOPT_HEADERDATA, static_cast<void*>(&m_response_headers));

  // Auto pre-resolve host to avoid curl's threaded resolver issues
#if !defined(_WIN32)
  {
    size_t scheme_pos = url.find("://");
    std::string scheme = scheme_pos != std::string::npos ? url.substr(0, scheme_pos) : std::string();
    size_t host_start = (scheme_pos != std::string::npos) ? scheme_pos + 3 : 0;
    size_t path_pos = url.find('/', host_start);
    size_t colon_pos = url.find(':', host_start);
    size_t host_end = (path_pos == std::string::npos) ? url.size() : path_pos;
    if (colon_pos != std::string::npos && colon_pos < host_end)
      host_end = colon_pos;
    if (host_end > host_start)
    {
      std::string host = url.substr(host_start, host_end - host_start);
      int port = (scheme == "https") ? 443 : 80;
      if (colon_pos != std::string::npos)
      {
        size_t port_end = (path_pos == std::string::npos) ? url.size() : path_pos;
        std::string port_str = url.substr(colon_pos + 1, port_end - (colon_pos + 1));
        if (!port_str.empty()) port = std::atoi(port_str.c_str());
      }
      PreResolveHost(host, port);
    }
  }
#endif

  std::vector<u8> buffer;
  curl_easy_setopt(m_curl.get(), CURLOPT_WRITEFUNCTION, CurlWriteCallback);
  curl_easy_setopt(m_curl.get(), CURLOPT_WRITEDATA, &buffer);

  const char* type = method == Method::POST ? "POST" : "GET";
  const CURLcode res = curl_easy_perform(m_curl.get());
  if (res != CURLE_OK)
  {
    ERROR_LOG_FMT(COMMON, "Failed to {} {}: {}", type, url, m_error_string);

#if defined(__APPLE__) && (TARGET_OS_IOS || TARGET_OS_TV)
    // Fallback to CFNetwork (system stack) on iOS/tvOS. curl failed (TLS/cert,
    // DNS, redirect, etc.); retry through the OS HTTP stack, which uses the
    // system trust store and follows redirects automatically.
    CFStringRef cf_url_str = CFStringCreateWithCString(kCFAllocatorDefault, url.c_str(), kCFStringEncodingUTF8);
    if (cf_url_str)
    {
      CFURLRef cf_url = CFURLCreateWithString(kCFAllocatorDefault, cf_url_str, nullptr);
      if (cf_url)
      {
        CFStringRef cf_method = CFStringCreateWithCString(kCFAllocatorDefault, type, kCFStringEncodingUTF8);
        CFHTTPMessageRef req = CFHTTPMessageCreateRequest(kCFAllocatorDefault, cf_method, cf_url, kCFHTTPVersion1_1);
        if (req)
        {
          // Minimal headers
          CFHTTPMessageSetHeaderFieldValue(req, CFSTR("User-Agent"), CFSTR("Dolphin/CFNetwork"));
          CFHTTPMessageSetHeaderFieldValue(req, CFSTR("Accept"), CFSTR("application/json"));
          if (method == Method::POST && payload && size > 0)
          {
            CFDataRef body = CFDataCreate(kCFAllocatorDefault, payload, size);
            if (body)
            {
              // Ensure RA/PHP parses form body like curl would
              CFHTTPMessageSetHeaderFieldValue(req, CFSTR("Content-Type"),
                                               CFSTR("application/x-www-form-urlencoded; charset=utf-8"));
              CFHTTPMessageSetBody(req, body);
              CFRelease(body);
            }
          }

          CFReadStreamRef stream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, req);
          if (stream)
          {
            Boolean autoRedirect = true;
            CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPShouldAutoredirect, autoRedirect ? kCFBooleanTrue : kCFBooleanFalse);
            if (CFReadStreamOpen(stream))
            {
              std::vector<u8> alt_buffer;
              u8 tmp[4096];
              CFIndex r = 0;
              while ((r = CFReadStreamRead(stream, (UInt8*)tmp, sizeof(tmp))) > 0)
              {
                alt_buffer.insert(alt_buffer.end(), tmp, tmp + r);
              }
              CFTypeRef resp_cf = CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
              long code = 0;
              if (resp_cf)
              {
                CFHTTPMessageRef resp = (CFHTTPMessageRef)resp_cf;
                code = CFHTTPMessageGetResponseStatusCode(resp);
                CFRelease(resp_cf);
              }
              CFReadStreamClose(stream);
              CFRelease(stream);
              CFRelease(req);
              CFRelease(cf_method);
              CFRelease(cf_url);
              CFRelease(cf_url_str);

              fprintf(stderr, "[HTTP] CFNetwork fallback %s %s -> %ld with %zu bytes\n", type, url.c_str(), code, alt_buffer.size());

              if (codes == AllowedReturnCodes::All)
                return alt_buffer;

              if (code != 200)
                return {};

              return alt_buffer;
            }
            CFRelease(stream);
          }
          CFRelease(req);
        }
        CFRelease(cf_method);
      }
      CFRelease(cf_url);
    }
#endif
    return {};
  }

  if (codes == AllowedReturnCodes::All)
    return buffer;

  long response_code = 0;
  curl_easy_getinfo(m_curl.get(), CURLINFO_RESPONSE_CODE, &response_code);
  if (response_code != 200)
  {
    if (buffer.empty())
    {
      ERROR_LOG_FMT(COMMON, "Failed to {} {}: server replied with code {}", type, url,
                    response_code);
    }
    else
    {
      ERROR_LOG_FMT(COMMON, "Failed to {} {}: server replied with code {} and body\n\x1b[0m{:.{}}",
                    type, url, response_code, reinterpret_cast<char*>(buffer.data()),
                    static_cast<int>(buffer.size()));
    }
    return {};
  }

  return buffer;
}
}  // namespace Common
