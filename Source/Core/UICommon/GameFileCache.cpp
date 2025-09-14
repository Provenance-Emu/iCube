// Copyright 2017 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "UICommon/GameFileCache.h"

#include <algorithm>
#include <cstddef>
#include <functional>
#include <list>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_set>
#include <utility>
#include <vector>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

#include "Common/ChunkFile.h"
#include "Common/CommonTypes.h"
#include "Common/FileSearch.h"
#include "Common/FileUtil.h"
#include "Common/IOFile.h"

#include "DiscIO/DirectoryBlob.h"

#include "UICommon/GameFile.h"

namespace UICommon
{
static constexpr u32 CACHE_REVISION = 25;  // Last changed in PR 12702

std::vector<std::string> FindAllGamePaths(const std::vector<std::string>& directories_to_scan,
                                          bool recursive_scan)
{
  static const std::vector<std::string> search_extensions = {
      ".gcm", ".tgc", ".iso", ".ciso", ".gcz", ".wbfs", ".wia",
      ".rvz", ".nfs", ".wad", ".dol",  ".elf", ".json"};

  // TODO: We could process paths iteratively as they are found
  return Common::DoFileSearch(directories_to_scan, search_extensions, recursive_scan);
}

GameFileCache::GameFileCache() : m_path(File::GetUserPath(D_CACHE_IDX) + "gamelist.cache")
{
}

void GameFileCache::ForEach(const ForEachFn& f) const
{
  for (const std::shared_ptr<GameFile>& item : m_cached_files)
  {
    // Critical safety check - skip null GameFile shared_ptrs in cache
    if (!item)
    {
      ERROR_LOG_FMT(DISCIO, "GameFileCache::ForEach: found null GameFile shared_ptr in cache, skipping");
      continue;
    }
    f(item);
  }
}

size_t GameFileCache::GetSize() const
{
  return m_cached_files.size();
}

void GameFileCache::Clear(DeleteOnDisk delete_on_disk)
{
  if (delete_on_disk != DeleteOnDisk::No)
    File::Delete(m_path);

  m_cached_files.clear();
}

std::shared_ptr<const GameFile> GameFileCache::AddOrGet(const std::string& path,
                                                        bool* cache_changed)
{
  auto it = std::find_if(
      m_cached_files.begin(), m_cached_files.end(),
      [&path](const std::shared_ptr<GameFile>& file) { return file->GetFilePath() == path; });
  const bool found = it != m_cached_files.cend();
  if (!found)
  {
    // Protect against empty paths in AddOrGet
    if (path.empty())
    {
      WARN_LOG_FMT(DISCIO, "GameFileCache::AddOrGet: empty path provided, returning nullptr");
      return nullptr;
    }

    std::shared_ptr<UICommon::GameFile> game = std::make_shared<GameFile>(path);
    if (!game->IsValid())
      return nullptr;
    m_cached_files.emplace_back(std::move(game));
  }
  std::shared_ptr<GameFile>& result = found ? *it : m_cached_files.back();
  if (UpdateAdditionalMetadata(&result) || !found)
    *cache_changed = true;

  return result;
}

bool GameFileCache::Update(std::span<const std::string> all_game_paths,
                           const GameAddedToCacheFn& game_added_to_cache,
                           const GameRemovedFromCacheFn& game_removed_from_cache,
                           const std::atomic_bool& processing_halted)
{
  INFO_LOG_FMT(DISCIO, "GameFileCache::Update called with {} paths", all_game_paths.size());

  // Filter valid game paths during iteration (addresses TODO about filter predicates)
  std::unordered_set<std::string> game_paths;
  game_paths.reserve(all_game_paths.size());
  size_t hidden_count = 0;

  for (const std::string& path : all_game_paths)
  {
    if (!DiscIO::ShouldHideFromGameList(path))
    {
      game_paths.insert(path);
      INFO_LOG_FMT(DISCIO, "GameFileCache::Update: added path to game_paths: {}", path);
    }
    else
    {
      hidden_count++;
      INFO_LOG_FMT(DISCIO, "GameFileCache::Update: path hidden from game list: {}", path);
    }
  }

  INFO_LOG_FMT(DISCIO, "GameFileCache::Update: processing {} valid paths ({} hidden)",
               game_paths.size(), hidden_count);
  bool cache_changed = false;

  // Delete paths that aren't in game_paths from m_cached_files,
  // while simultaneously deleting paths that are in m_cached_files from game_paths.
  // For the sake of speed, we don't care about maintaining the order of m_cached_files.
  {
    auto it = m_cached_files.begin();
    auto end = m_cached_files.end();
    while (it != end)
    {
      if (processing_halted)
        break;

      const std::string& cached_path = (*it)->GetFilePath();
      if (game_paths.erase(cached_path))
      {
        // Check if this is a remote RVZ file that failed title extraction and needs re-processing
        bool is_rvz = cached_path.find(".rvz") != std::string::npos;
        bool is_remote = (cached_path.find("http://") == 0 || cached_path.find("https://") == 0 ||
                         cached_path.find("webdav://") == 0 || cached_path.find("webdavs://") == 0);
        bool no_title = (*it)->GetLongName().empty() && (*it)->GetShortName().empty();

        if (is_rvz && is_remote && no_title && (*it)->IsValid())
        {
          INFO_LOG_FMT(DISCIO, "GameFileCache::Update: Remote RVZ file '{}' has no extracted title (gameID: '{}'), re-processing with HttpRVZReader",
                      cached_path, (*it)->GetGameID());

          // Remove from cache so it gets re-processed with the new HttpRVZReader
          if (game_removed_from_cache)
            game_removed_from_cache(cached_path);

          // Re-add to game_paths for re-processing
          game_paths.insert(cached_path);

          cache_changed = true;
          --end;
          *it = std::move(*end);
        }
        else
        {
          if (is_rvz && is_remote && !no_title)
          {
            INFO_LOG_FMT(DISCIO, "GameFileCache::Update: Remote RVZ file '{}' already has title '{}', keeping cached version",
                        cached_path, (*it)->GetLongName().empty() ? (*it)->GetShortName() : (*it)->GetLongName());
          }
          ++it;
        }
      }
      else
      {
        if (game_removed_from_cache)
          game_removed_from_cache(cached_path);

        cache_changed = true;
        --end;
        *it = std::move(*end);
      }
    }
    m_cached_files.erase(it, m_cached_files.end());
  }

  // Now that the previous loop has run, game_paths only contains paths that
  // aren't in m_cached_files, so we simply add all of them to m_cached_files.
  for (const std::string& path : game_paths)
  {
    if (processing_halted)
      break;

    // Skip empty or invalid paths to prevent crashes
    if (path.empty())
    {
      WARN_LOG_FMT(DISCIO, "GameFileCache::Update: skipping empty path");
      continue;
    }

    INFO_LOG_FMT(DISCIO, "GameFileCache::Update: creating GameFile for path: {}", path);
    auto file = std::make_shared<GameFile>(path);
    if (file->IsValid())
    {
      INFO_LOG_FMT(DISCIO, "GameFileCache::Update: GameFile is valid, adding to cache: {}", path);
      if (game_added_to_cache)
        game_added_to_cache(file);

      cache_changed = true;
      m_cached_files.push_back(std::move(file));
    }
    else
    {
      INFO_LOG_FMT(DISCIO, "GameFileCache::Update: GameFile is invalid, not adding to cache: {}", path);
    }
  }

  INFO_LOG_FMT(DISCIO, "GameFileCache::Update: finished, cache_changed={}, total cached files={}", cache_changed, m_cached_files.size());
  return cache_changed;
}

bool GameFileCache::UpdateAdditionalMetadata(const GameUpdatedFn& game_updated,
                                             const std::atomic_bool& processing_halted)
{
  bool cache_changed = false;

  for (std::shared_ptr<GameFile>& file : m_cached_files)
  {
    if (processing_halted)
      break;

    // Guard against null entries that may exist after cache load
    if (!file)
      continue;

    const bool updated = UpdateAdditionalMetadata(&file);
    cache_changed |= updated;
    if (game_updated && updated)
      game_updated(file);
  }

  // Compact any null entries that may remain to avoid future crashes
  m_cached_files.erase(std::remove(m_cached_files.begin(), m_cached_files.end(), nullptr),
                       m_cached_files.end());

  return cache_changed;
}

void GameFileCache::LoadRemoteMetadataAsync(const std::string& file_path)
{
  // Schedule async loading of covers/banners for remote files
  // This runs on a background thread to avoid blocking the UI
  std::thread([this, file_path]() {
    // Find the game file in cache
    auto it = std::find_if(
        m_cached_files.begin(), m_cached_files.end(),
        [&file_path](const std::shared_ptr<GameFile>& file) { return file->GetFilePath() == file_path; });

    if (it != m_cached_files.end())
    {
      INFO_LOG_FMT(DISCIO, "GameFileCache::LoadRemoteMetadataAsync: loading metadata for {}", file_path);
      std::shared_ptr<GameFile> game_file = *it;
      // Force update metadata on background thread
      UpdateAdditionalMetadata(&game_file);

      // Replace the cached version with updated one
      *it = game_file;

            INFO_LOG_FMT(DISCIO, "GameFileCache::LoadRemoteMetadataAsync: completed for {}", file_path);

      // Notify UI that metadata has been updated (iOS/macOS specific)
#ifdef __OBJC__
      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"GameFileMetadataUpdated"
                                                            object:nil
                                                          userInfo:@{@"filePath": [NSString stringWithUTF8String:file_path.c_str()]}];
      });
#endif
    }
  }).detach();
}

bool GameFileCache::UpdateAdditionalMetadata(std::shared_ptr<GameFile>* game_file)
{
  // Safety guards against null pointers
  if (!game_file || !(*game_file))
    return false;

  // Check if this is a remote file that might need async metadata loading
  const std::string& file_path = (*game_file)->GetFilePath();
  bool is_remote = (file_path.find("http://") == 0 || file_path.find("https://") == 0 ||
                    file_path.find("webdav://") == 0 || file_path.find("webdavs://") == 0);

#ifdef __OBJC__
  bool is_main_thread = [NSThread isMainThread];
#else
  bool is_main_thread = false; // Assume not main thread on non-Apple platforms
#endif

  // If we're on main thread with a remote file, schedule async loading and return
  if (is_remote && is_main_thread)
  {
    INFO_LOG_FMT(DISCIO, "GameFileCache::UpdateAdditionalMetadata: scheduling async metadata loading for {}", file_path);
    LoadRemoteMetadataAsync(file_path);
    return false; // No immediate changes to cache
  }

  const bool xml_metadata_changed = (*game_file)->XMLMetadataChanged();
  const bool wii_banner_changed = (*game_file)->WiiBannerChanged();
  const bool custom_banner_changed = (*game_file)->CustomBannerChanged();

  (*game_file)->DownloadDefaultCover();

  bool default_cover_changed = false;
#ifdef __OBJC__
  if (![NSThread isMainThread])
  {
    // Perform DefaultCoverChanged on main thread synchronously to avoid races with UI/lifecycle
    __block bool changed = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
      changed = (*game_file)->DefaultCoverChanged();
    });
    default_cover_changed = changed;
  }
  else
#endif
  {
    default_cover_changed = (*game_file)->DefaultCoverChanged();
  }
  const bool custom_cover_changed = (*game_file)->CustomCoverChanged();

  if (!xml_metadata_changed && !wii_banner_changed && !custom_banner_changed &&
      !default_cover_changed && !custom_cover_changed)
  {
    return false;
  }

  // If a cached file needs an update, apply the updates to a copy and delete the original.
  // This makes the usage of cached files in other threads safe.

  std::shared_ptr<GameFile> copy = std::make_shared<GameFile>(**game_file);
  if (xml_metadata_changed)
    copy->XMLMetadataCommit();
  if (wii_banner_changed)
    copy->WiiBannerCommit();
  if (custom_banner_changed)
    copy->CustomBannerCommit();
  if (default_cover_changed)
    copy->DefaultCoverCommit();
  if (custom_cover_changed)
    copy->CustomCoverCommit();

  *game_file = std::move(copy);

  return true;
}

bool GameFileCache::Load()
{
  return SyncCacheFile(false);
}

bool GameFileCache::Save()
{
  return SyncCacheFile(true);
}

bool GameFileCache::SyncCacheFile(bool save)
{
  const char* open_mode = save ? "wb" : "rb";
  File::IOFile f(m_path, open_mode);
  if (!f)
    return false;
  bool success = false;
  if (save)
  {
    // Measure the size of the buffer.
    u8* ptr = nullptr;
    PointerWrap p_measure(&ptr, 0, PointerWrap::Mode::Measure);
    DoState(&p_measure);
    const size_t buffer_size = reinterpret_cast<size_t>(ptr);

    // Then actually do the write.
    std::vector<u8> buffer(buffer_size);
    ptr = buffer.data();
    PointerWrap p(&ptr, buffer_size, PointerWrap::Mode::Write);
    DoState(&p, buffer_size);
    if (f.WriteBytes(buffer.data(), buffer.size()))
      success = true;
  }
  else
  {
    std::vector<u8> buffer(f.GetSize());
    if (!buffer.empty() && f.ReadBytes(buffer.data(), buffer.size()))
    {
      u8* ptr = buffer.data();
      PointerWrap p(&ptr, buffer.size(), PointerWrap::Mode::Read);
      DoState(&p, buffer.size());
      if (p.IsReadMode())
        success = true;
    }
  }
  if (!success)
  {
    // If some file operation failed, try to delete the probably-corrupted cache
    f.Close();
    File::Delete(m_path);
  }
  return success;
}

void GameFileCache::DoState(PointerWrap* p, u64 size)
{
  struct
  {
    u32 revision;
    u64 expected_size;
  } header = {CACHE_REVISION, size};
  p->Do(header);
  if (p->IsReadMode())
  {
    if (header.revision != CACHE_REVISION || header.expected_size != size)
    {
      p->SetMeasureMode();
      return;
    }
  }
  p->DoEachElement(m_cached_files, [](PointerWrap& state, std::shared_ptr<GameFile>& elem) {
    if (state.IsReadMode())
    {
      elem = std::make_shared<GameFile>();
    }
    elem->DoState(state);

    // Safety check: verify loaded GameFile is valid and has non-empty path
    if (state.IsReadMode() && (!elem->IsValid() || elem->GetFilePath().empty()))
    {
      ERROR_LOG_FMT(DISCIO, "GameFileCache: loaded invalid GameFile from cache, path: '{}', setting to null",
                    elem->GetFilePath());
      elem.reset(); // Set to null to be filtered out by ForEach
    }
  });
}

}  // namespace UICommon
