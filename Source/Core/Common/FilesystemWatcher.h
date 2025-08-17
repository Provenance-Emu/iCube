// Copyright 2025 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <map>
#include <memory>
#include <string>
#include <string_view>

#if defined(__APPLE__)
 #include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && !TARGET_OS_IPHONE && !TARGET_OS_TV
 #define COMMON_WATCHER_ENABLED 1
 namespace wtr
 {
 inline namespace watcher
 {
 class watch;
 }
 }  // namespace wtr
#else
 #define COMMON_WATCHER_ENABLED 0
#endif

namespace Common
{
// A class that can watch a path and receive callbacks
// when files or directories underneath that path receive events
class FilesystemWatcher
{
public:
  FilesystemWatcher();
  virtual ~FilesystemWatcher();

  void Watch(const std::string& path);
  void Unwatch(const std::string& path);

private:
  // A new file or folder was added to one of the watched paths
  virtual void PathAdded(std::string_view path) {}

  // A file or folder was modified in one of the watched paths
  virtual void PathModified(std::string_view path) {}

  // A file or folder was renamed in one of the watched paths
  virtual void PathRenamed(std::string_view old_path, std::string_view new_path) {}

  // A file or folder was deleted in one of the watched paths
  virtual void PathDeleted(std::string_view path) {}

 #if COMMON_WATCHER_ENABLED
   std::map<std::string, std::unique_ptr<wtr::watch>> m_watched_paths;
 #else
   // Placeholder to track watched paths when watcher is disabled on platform
   std::map<std::string, bool> m_watched_paths;
 #endif
};
}  // namespace Common
