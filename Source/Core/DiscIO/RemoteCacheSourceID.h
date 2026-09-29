// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <algorithm>
#include <charconv>
#include <string>
#include <string_view>
#include <system_error>

namespace DiscIO
{
// Cache folder ID for a remote (WebDAV/HTTP) game URL: "{host}_{port}" with '.' and ':' replaced by
// '_'. Must match WebDAVSource.generateConsistentId in Swift, which uses URL.host (no user info, no
// IPv6 brackets) and URL.port or the scheme default (443 for https, 80 otherwise). Never throws: this
// used std::stoi on everything after the first ':', which threw for "user:pass@host" and "[::1]"
// URLs on the library scan's queue, crash-looping every launch (Sentry ICUBE-87). Expects a
// lower-cased URL with "://"; returns an empty string otherwise.
inline std::string RemoteCacheSourceID(std::string_view url)
{
  const size_t scheme_end = url.find("://");
  if (scheme_end == std::string_view::npos)
    return {};
  const bool https = url.substr(0, scheme_end) == "https";

  std::string_view authority = url.substr(scheme_end + 3);
  authority = authority.substr(0, authority.find_first_of("/?#"));
  if (const size_t at = authority.rfind('@'); at != std::string_view::npos)
    authority = authority.substr(at + 1);

  std::string_view host = authority;
  std::string_view port_text;
  if (!authority.empty() && authority.front() == '[')
  {
    const size_t close = authority.find(']');
    host = authority.substr(1, close == std::string_view::npos ? std::string_view::npos : close - 1);
    if (close != std::string_view::npos && authority.substr(close + 1).starts_with(':'))
      port_text = authority.substr(close + 2);
  }
  else if (const size_t colon = authority.rfind(':'); colon != std::string_view::npos)
  {
    host = authority.substr(0, colon);
    port_text = authority.substr(colon + 1);
  }

  int port = https ? 443 : 80;
  int parsed = 0;
  const char* const port_end = port_text.data() + port_text.size();
  const auto [parse_end, error] = std::from_chars(port_text.data(), port_end, parsed);
  if (error == std::errc() && parse_end == port_end && parsed > 0 && parsed <= 65535)
    port = parsed;

  std::string source_id = std::string(host) + ":" + std::to_string(port);
  std::ranges::replace(source_id, '.', '_');
  std::ranges::replace(source_id, ':', '_');
  return source_id;
}
}  // namespace DiscIO
