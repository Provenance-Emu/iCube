// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import "DOLControllerInputLease.h"
#include "InputCommon/ControllerInterface/iOS/MFiController.h"

using ciface::iOS::ControllerInputGate;
using ciface::iOS::MFiController;

@implementation DOLControllerInputLease
{
  GCController* _controller;
  std::shared_ptr<ControllerInputGate> _gate;
  ControllerInputGate::Token _token;
}
- (instancetype)initWithController:(GCController*)controller
{
  if ((self = [super init]))
  {
    _controller = controller;
    _gate = MFiController::GetInputGate(controller);
    _token = _gate->Acquire();
  }
  return self;
}
- (void)requestRelease
{
  // RequestRelease is idempotent and synchronized in the shared gate, including deallocation.
  _gate->RequestRelease(_token);
}
- (BOOL)pollRelease
{
  _gate->PollNeutral([&] { return MFiController::AreControlsNeutral(_controller); });
  return _gate->IsDisconnected() || !_gate->IsSuppressed();
}
- (void)forceReleaseForDisconnect
{
  MFiController::DisconnectInputGate(_controller, _gate);
}
- (void)dealloc
{
  // Native UpdateInput owns the pending-neutral fence even if the UI drops its lease object.
  _gate->RequestRelease(_token);
}
@end
