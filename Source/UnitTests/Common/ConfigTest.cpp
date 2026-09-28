// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <chrono>
#include <functional>
#include <future>
#include <memory>
#include <thread>
#include <utility>

#include <gtest/gtest.h>

#include "Common/Config/Config.h"

namespace
{
const Config::Info<int> TEST_SETTING{{Config::System::Main, "ConfigTest", "Value"}, 0};

// Does what BaseConfigLayerLoader::Save does through SaveToSYSCONF: reads config through
// Config::Get(LayerType, info), which takes the layers lock. `before_read` runs first.
class ReadingLoader final : public Config::ConfigLayerLoader
{
public:
  explicit ReadingLoader(std::function<void()> before_read)
      : ConfigLayerLoader(Config::LayerType::CommandLine), m_before_read(std::move(before_read))
  {
  }

  void Load(Config::Layer*) override {}

  void Save(Config::Layer*) override
  {
    if (m_before_read)
      m_before_read();
    Config::Get(Config::LayerType::CommandLine, TEST_SETTING);
  }

private:
  std::function<void()> m_before_read;
};
}  // namespace

// Config::Save() used to hold the layers read lock while calling each loader's Save(). A loader
// that reads config (the base loader does, for SYSCONF) then takes the read lock again on the same
// thread, and std::shared_mutex blocks that second read once a writer is queued (libc++ on
// iOS/macOS/Android does). The saver waits for the writer, the writer for the saver, and every
// other reader behind the writer: the fatal main-thread hang in Sentry ICUBE-2D, where the 0.8 s
// debounced Config::Save() on main met Config::RemoveLayer on the CPU-GPU thread at shutdown.
TEST(Config, SaveDoesNotDeadlockWhenALayerIsRemovedDuringTheSave)
{
  std::thread writer;
  bool writer_started = false;
  Config::AddLayer(std::make_unique<ReadingLoader>([&writer, &writer_started] {
    if (std::exchange(writer_started, true))
      return;
    // Queue a writer, and give it time to start waiting, before the loader's read.
    writer = std::thread([] { Config::RemoveLayer(Config::LayerType::Movie); });
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }));
  Config::Set(Config::LayerType::CommandLine, TEST_SETTING, 1);  // Save() skips clean layers

  std::promise<void> saved;
  auto saved_future = saved.get_future();
  std::thread saver([&saved] {
    Config::Save();
    saved.set_value();
  });

  const bool finished =
      saved_future.wait_for(std::chrono::seconds(5)) == std::future_status::ready;
  if (!finished)
  {
    // Deadlocked: these threads never return, so they cannot be joined.
    saver.detach();
    writer.detach();
    FAIL() << "Config::Save() deadlocked against a queued Config::RemoveLayer()";
  }
  saver.join();
  writer.join();

  // The loader reads on every save, so drop it before other tests run.
  Config::RemoveLayer(Config::LayerType::CommandLine);
}
