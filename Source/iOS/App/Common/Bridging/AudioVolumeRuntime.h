// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#import <Foundation/Foundation.h>
#import "HostQueue.h"

#include "AudioCommon/AudioCommon.h"
#include "Core/Core.h"
#include "Core/System.h"

/// Config stores the requested level; each live backend also owns its output gain.
/// Serialize gain updates with host boot/stop work without blocking the UI or
/// retaining a stream that shutdown could destroy before this job runs.
inline void ICubeUpdateAudioVolumeAsync()
{
  void (^enqueue)(void) = ^{
    DOLHostQueueRunAsync(^{
      auto& system = Core::System::GetInstance();
      const Core::State state = Core::GetState(system);
      // EmulationCoordinator replays Config once the boot leaves Starting.
      if (state == Core::State::Starting || state == Core::State::Stopping)
        return;
      // Null is normal in settings before/after a game. The next boot reads Config.
      AudioCommon::UpdateSoundStream(system);
    });
  };
  if ([NSThread isMainThread])
    enqueue();
  else
    // DOLHostQueueRunAsync rejects reentrant calls on its own queue. Enter from
    // main even for a non-UI caller, and never synchronously wait for boot/JIT.
    dispatch_async(dispatch_get_main_queue(), enqueue);
}
