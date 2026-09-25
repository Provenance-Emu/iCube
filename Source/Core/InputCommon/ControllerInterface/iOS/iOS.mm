// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "InputCommon/ControllerInterface/iOS/iOS.h"

#include "InputCommon/ControllerInterface/iOS/MFiController.h"
#include "InputCommon/ControllerInterface/iOS/MFiControllerScanner.h"
#include "InputCommon/ControllerInterface/iOS/MFiKeyboard.h"
#include "InputCommon/ControllerInterface/iOS/StateManager.h"
#include "InputCommon/ControllerInterface/iOS/Touchscreen.h"

namespace ciface::iOS
{
class InputBackend final : public ciface::InputBackend
{
public:
  InputBackend(ControllerInterface* controller_interface);
  ~InputBackend();
  void PopulateDevices() override;

private:
  MFiControllerScanner* m_mfi_scanner;
};

std::unique_ptr<ciface::InputBackend> CreateInputBackend(ControllerInterface* controller_interface)
{
  return std::make_unique<InputBackend>(controller_interface);
}

InputBackend::InputBackend(ControllerInterface* controller_interface)
    : ciface::InputBackend(controller_interface)
{
  StateManager::GetInstance()->Init();

  m_mfi_scanner = [[MFiControllerScanner alloc] init];
}

InputBackend::~InputBackend()
{
  StateManager::GetInstance()->DeInit();

  m_mfi_scanner = nil;
}

void InputBackend::PopulateDevices()
{
  for (int i = 0; i < 8; ++i)
    g_controller_interface.AddDevice(std::make_shared<ciface::iOS::Touchscreen>(
        i, i >= 4));

  // Reconcile MFi id bookkeeping against the live controller list BEFORE constructing any
  // wrapper below, so a device-refresh rebuild (which tears down and recreates every wrapper,
  // even for pads that never disconnected) doesn't free ordinals out from under still-connected
  // pads. See MFiController::GetPreferredId / defect #16.
  NSArray<GCController*>* live_controllers = [GCController controllers];
  MFiController::PruneStaleIds(live_controllers);
  for (GCController* controller in live_controllers)
    g_controller_interface.AddDevice(std::make_shared<MFiController>(controller));

  for (GCKeyboard* keyboard in [m_mfi_scanner keyboards])
    g_controller_interface.AddDevice(std::make_shared<MFiKeyboard>(keyboard));
}
}  // namespace ciface::iOS
