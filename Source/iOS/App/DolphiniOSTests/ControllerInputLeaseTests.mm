// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import <XCTest/XCTest.h>
#import <GameController/GameController.h>
#import "../Common/Bridging/DOLControllerInputLease.h"
#include "InputCommon/ControllerInterface/iOS/MFiController.h"

// Keep the real native wrappers and GameController button/axis objects. The fixture supplies
// only immutable framework discovery/motion properties, without connecting hardware or a ROM.
@interface DOLGateMotionFixture : NSObject
@end
@implementation DOLGateMotionFixture
- (BOOL)sensorsRequireManualActivation { return NO; }
- (BOOL)hasRotationRate { return YES; }
- (GCAcceleration)acceleration { return (GCAcceleration){0.25, 0.5, 1.0}; }
- (GCRotationRate)rotationRate { return (GCRotationRate){1.0, 2.0, 3.0}; }
@end

@interface DOLGateProfileFixture : NSObject
@property(nonatomic, strong) NSDictionary<NSString*, GCControllerElement*>* elements;
@end
@implementation DOLGateProfileFixture
- (instancetype)capture { return self; }
@end

@interface DOLGateControllerFixture : NSObject
@property(nonatomic, strong) GCExtendedGamepad* extendedGamepad;
@property(nonatomic, strong) GCMicroGamepad* microGamepad;
@property(nonatomic, strong) DOLGateProfileFixture* physicalInputProfile;
@property(nonatomic, strong) DOLGateMotionFixture* motion;
@end
@implementation DOLGateControllerFixture
- (NSString*)vendorName { return @"Gate Test Controller"; }
- (NSString*)productCategory { return @"Gate Test"; }
- (GCGamepad*)gamepad { return nil; }
- (GCDeviceHaptics*)haptics { return nil; }
@end

namespace
{
using ciface::iOS::MFiController;
DOLGateControllerFixture* ExtendedFixture()
{
  DOLGateControllerFixture* fixture = [DOLGateControllerFixture new];
  fixture.extendedGamepad = [GCController controllerWithExtendedGamepad].extendedGamepad;
  fixture.physicalInputProfile = [DOLGateProfileFixture new];
  fixture.physicalInputProfile.elements = fixture.extendedGamepad.elements;
  fixture.motion = [DOLGateMotionFixture new];
  return fixture;
}
GCController* Identity(DOLGateControllerFixture* fixture)
{
  return (GCController*)(id)fixture;
}
}

@interface ControllerInputLeaseTests : XCTestCase
@end
@implementation ControllerInputLeaseTests
- (void)testActualBackendInputsAreNeutralWhileExactControllerIsLeased
{
  auto fixture = ExtendedFixture();
  auto other = ExtendedFixture();
  GCController* remote = Identity(fixture);
  [fixture.extendedGamepad.buttonA setValue:1];
  [fixture.extendedGamepad.leftTrigger setValue:0.75f];
  [fixture.extendedGamepad.leftThumbstick.xAxis setValue:0.5f];
  [other.extendedGamepad.buttonA setValue:1];
  MFiController wrapper(remote);
  MFiController pad(Identity(other));
  const char* names[] = {"Button A", "L Trigger", "L Stick X+", "Accel Up", "Gyro Pitch Up"};
  for (const char* name : names)
  {
    XCTAssertNotEqual(wrapper.FindInput(name), nullptr);
    XCTAssertNotEqual(wrapper.FindInput(name)->GetState(), 0.0, @"%s baseline", name);
  }
  auto lease = [[DOLControllerInputLease alloc] initWithController:remote];
  MFiController refreshed(remote);
  for (const char* name : names)
  {
    XCTAssertEqual(wrapper.FindInput(name)->GetState(), 0.0, @"%s leased", name);
    XCTAssertEqual(refreshed.FindInput(name)->GetState(), 0.0, @"%s refreshed", name);
  }
  for (auto* input : wrapper.Inputs())
    XCTAssertEqual(input->GetState(), 0.0, @"%s", input->GetName().c_str());
  XCTAssertEqual(pad.FindInput("Button A")->GetState(), 1.0);
  [lease requestRelease];
  XCTAssertFalse([lease pollRelease]);
  [fixture.extendedGamepad.buttonA setValue:0];
  [fixture.extendedGamepad.leftTrigger setValue:0];
  XCTAssertFalse([lease pollRelease]); // held axis alone still fences release
  [fixture.extendedGamepad.leftThumbstick.xAxis setValue:0];
  XCTAssertTrue([lease pollRelease]); // gravity/rotation never block physical neutral
  XCTAssertNotEqual(wrapper.FindInput("Accel Up")->GetState(), 0.0);
  MFiController::ReleaseId(remote);
  MFiController::ReleaseId(Identity(other));
}

- (void)testNestedLeasesAndAbandonedLeaseReleaseThroughBackendPolling
{
  auto fixture = ExtendedFixture();
  GCController* controller = Identity(fixture);
  MFiController wrapper(controller);
  auto first = [[DOLControllerInputLease alloc] initWithController:controller];
  auto second = [[DOLControllerInputLease alloc] initWithController:controller];
  [first requestRelease];
  XCTAssertFalse([first pollRelease]);
  [fixture.extendedGamepad.buttonA setValue:1];
  second = nil; // dealloc must preserve the physical release fence
  wrapper.UpdateInput();
  XCTAssertEqual(wrapper.FindInput("Button A")->GetState(), 0.0);
  [fixture.extendedGamepad.buttonA setValue:0];
  wrapper.UpdateInput();
  XCTAssertTrue([first pollRelease]);
  [fixture.extendedGamepad.buttonA setValue:1];
  XCTAssertEqual(wrapper.FindInput("Button A")->GetState(), 1.0);
  MFiController::ReleaseId(controller);
}

- (void)testMicroRemoteAndMissedDisconnectPruning
{
  auto fixture = ExtendedFixture();
  fixture.extendedGamepad = nil;
  fixture.microGamepad = [GCController controllerWithMicroGamepad].microGamepad;
  fixture.physicalInputProfile.elements = fixture.microGamepad.elements;
  GCController* controller = Identity(fixture);
  [fixture.microGamepad.buttonA setValue:1];
  MFiController wrapper(controller);
  XCTAssertEqual(wrapper.FindInput("Button A")->GetState(), 1.0);
  auto lease = [[DOLControllerInputLease alloc] initWithController:controller];
  XCTAssertEqual(wrapper.FindInput("Button A")->GetState(), 0.0);
  [lease requestRelease];
  XCTAssertFalse([lease pollRelease]);
  MFiController::PruneStaleIds(@[]);
  XCTAssertTrue([lease pollRelease]);
  XCTAssertEqual(wrapper.FindInput("Button A")->GetState(), 0.0);
}

- (void)testStaleLeaseDisconnectCannotRemoveReplacementGateForSameIdentity
{
  auto fixture = ExtendedFixture();
  GCController* controller = Identity(fixture);
  [fixture.extendedGamepad.buttonA setValue:1];
  auto oldLease = [[DOLControllerInputLease alloc] initWithController:controller];
  MFiController oldWrapper(controller);
  [oldLease forceReleaseForDisconnect];

  auto newLease = [[DOLControllerInputLease alloc] initWithController:controller];
  auto replacementGate = MFiController::GetInputGate(controller);
  MFiController newWrapper(controller);
  [oldLease forceReleaseForDisconnect]; // stale repeated teardown must only affect its own gate
  [oldLease requestRelease];
  XCTAssertTrue([oldLease pollRelease]);
  XCTAssertTrue(MFiController::GetInputGate(controller) == replacementGate);
  XCTAssertFalse(replacementGate->IsDisconnected());
  XCTAssertFalse([newLease pollRelease]);
  MFiController refreshed(controller);
  XCTAssertEqual(refreshed.FindInput("Button A")->GetState(), 0.0);
  XCTAssertEqual(oldWrapper.FindInput("Button A")->GetState(), 0.0);
  [newLease requestRelease];
  XCTAssertFalse([newLease pollRelease]);
  [fixture.extendedGamepad.buttonA setValue:0];
  XCTAssertTrue([newLease pollRelease]);
  [fixture.extendedGamepad.buttonA setValue:1];
  XCTAssertEqual(newWrapper.FindInput("Button A")->GetState(), 1.0);
  MFiController::ReleaseId(controller);
}

- (void)testPhysicalFallbackAndDisconnectDoNotLeakHeldInputs
{
  auto fixture = ExtendedFixture();
  GCExtendedGamepad* inputs = fixture.extendedGamepad;
  fixture.extendedGamepad = nil;
  fixture.physicalInputProfile.elements = @{@"Direction Pad": inputs.dpad,
                                            @"Button A": inputs.buttonA,
                                            @"Left Trigger": inputs.leftTrigger};
  GCController* controller = Identity(fixture);
  [inputs.buttonA setValue:1];
  MFiController wrapper(controller);
  XCTAssertNotEqual(wrapper.FindInput("Button A"), nullptr);
  XCTAssertEqual(wrapper.FindInput("Button A")->GetState(), 1.0);
  auto lease = [[DOLControllerInputLease alloc] initWithController:controller];
  XCTAssertEqual(wrapper.FindInput("Button A")->GetState(), 0.0);
  [lease forceReleaseForDisconnect];
  XCTAssertTrue([lease pollRelease]);
  [lease requestRelease];
  wrapper.UpdateInput();
  XCTAssertEqual(wrapper.FindInput("Button A")->GetState(), 0.0);
  // The registry removed the old identity entry; neither its token nor stale wrappers gate
  // a newly populated wrapper. The old wrapper stays neutral until destruction.
  MFiController reconnected(controller);
  XCTAssertEqual(reconnected.FindInput("Button A")->GetState(), 1.0);
  XCTAssertEqual(wrapper.FindInput("Button A")->GetState(), 0.0);
  MFiController::ReleaseId(controller);
}
@end
