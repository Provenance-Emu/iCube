// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import <XCTest/XCTest.h>
#import <GameController/GameController.h>

#include <algorithm>
#include <cmath>

#include "Common/MathUtil.h"
#include "Common/Matrix.h"
#include "Core/HW/WiimoteEmu/Dynamics.h"
#include "InputCommon/ControllerInterface/iOS/MFiController.h"

// A pad whose motion sensors read whatever the test sets. GCMotion's frame, from the pad's point
// of view when it lies flat, face up: x right, y forward (out of the top edge), z up (out of the
// face). `acceleration` is in g and uses Apple's sign: at rest it is the direction gravity pulls,
// so a pad lying face up reads (0, 0, -1) (GCMotion.h, GCAcceleration).
@interface DOLAxisMotionFixture : NSObject
@property(nonatomic) GCAcceleration acceleration;
@property(nonatomic) GCRotationRate rotationRate;
@end
@implementation DOLAxisMotionFixture
- (BOOL)sensorsRequireManualActivation { return NO; }
- (BOOL)hasRotationRate { return YES; }
@end

@interface DOLAxisProfileFixture : NSObject
@property(nonatomic, strong) NSDictionary<NSString*, GCControllerElement*>* elements;
@end
@implementation DOLAxisProfileFixture
- (instancetype)capture { return self; }
@end

@interface DOLAxisControllerFixture : NSObject
@property(nonatomic, strong) GCExtendedGamepad* extendedGamepad;
@property(nonatomic, strong) DOLAxisProfileFixture* physicalInputProfile;
@property(nonatomic, strong) DOLAxisMotionFixture* motion;
@end
@implementation DOLAxisControllerFixture
- (NSString*)vendorName { return @"Axis Test Controller"; }
- (NSString*)productCategory { return @"Axis Test"; }
- (GCMicroGamepad*)microGamepad { return nil; }
- (GCGamepad*)gamepad { return nil; }
- (GCDeviceHaptics*)haptics { return nil; }
@end

namespace
{
using ciface::iOS::MFiController;

const double g = MathUtil::GRAVITY_ACCELERATION;

DOLAxisControllerFixture* MotionPad()
{
  DOLAxisControllerFixture* fixture = [DOLAxisControllerFixture new];
  fixture.extendedGamepad = [GCController controllerWithExtendedGamepad].extendedGamepad;
  fixture.physicalInputProfile = [DOLAxisProfileFixture new];
  fixture.physicalInputProfile.elements = fixture.extendedGamepad.elements;
  fixture.motion = [DOLAxisMotionFixture new];
  return fixture;
}

// One half of an axis as the core reads it: ControlExpression clamps a negative input to zero.
double Half(const MFiController& pad, const char* name)
{
  return std::max(0.0, pad.FindInput(name)->GetState());
}

// The emulated Wii Remote's accelerometer, as IMUAccelerometer::GetState combines the halves of
// the stock profile: x toward the remote's left, y toward its back end, z out of its top. A real
// remote lying flat reads (0, 0, +g): the force holding it up.
Common::Vec3 RemoteAcceleration(const MFiController& pad)
{
  return Common::Vec3(float(Half(pad, "Accel Left") - Half(pad, "Accel Right")),
                      float(Half(pad, "Accel Back") - Half(pad, "Accel Forward")),
                      float(Half(pad, "Accel Up") - Half(pad, "Accel Down")));
}

// The emulated MotionPlus rates, as IMUGyroscope::GetRawState combines them.
Common::Vec3 RemoteAngularVelocity(const MFiController& pad)
{
  return Common::Vec3(float(Half(pad, "Gyro Pitch Down") - Half(pad, "Gyro Pitch Up")),
                      float(Half(pad, "Gyro Roll Left") - Half(pad, "Gyro Roll Right")),
                      float(Half(pad, "Gyro Yaw Left") - Half(pad, "Gyro Yaw Right")));
}
}  // namespace

@interface MFiMotionAxisTests : XCTestCase
@end

@implementation MFiMotionAxisTests
{
  DOLAxisControllerFixture* _fixture;
}

- (void)setUp
{
  _fixture = MotionPad();
}

- (void)tearDown
{
  MFiController::ReleaseId((GCController*)(id)_fixture);
}

- (void)expectPadAcceleration:(GCAcceleration)pad
            readsOnTheRemoteAs:(Common::Vec3)expected
                          pose:(NSString*)pose
{
  _fixture.motion.acceleration = pad;
  MFiController device((GCController*)(id)_fixture);
  const Common::Vec3 remote = RemoteAcceleration(device);
  XCTAssertEqualWithAccuracy(remote.x, expected.x, 1e-4, @"%@: left/right", pose);
  XCTAssertEqualWithAccuracy(remote.y, expected.y, 1e-4, @"%@: back/forward", pose);
  XCTAssertEqualWithAccuracy(remote.z, expected.z, 1e-4, @"%@: up/down", pose);
}

// The report this guards: with every sign reversed, a pad lying flat told the game its Wii Remote
// was upside down, so the pointer was drawn rotated 180 degrees and swings needed the pad held
// backwards and upside down.
- (void)testAPadAtRestReadsAsAWiiRemoteInTheSamePose
{
  const float G = float(g);
  [self expectPadAcceleration:{0, 0, -1} readsOnTheRemoteAs:{0, 0, G} pose:@"flat, face up"];
  [self expectPadAcceleration:{0, 0, 1} readsOnTheRemoteAs:{0, 0, -G} pose:@"flat, face down"];
  [self expectPadAcceleration:{0, -1, 0} readsOnTheRemoteAs:{0, -G, 0} pose:@"pointing at the ceiling"];
  [self expectPadAcceleration:{0, 1, 0} readsOnTheRemoteAs:{0, G, 0} pose:@"pointing at the floor"];
  [self expectPadAcceleration:{1, 0, 0} readsOnTheRemoteAs:{G, 0, 0} pose:@"right side down"];
  [self expectPadAcceleration:{-1, 0, 0} readsOnTheRemoteAs:{-G, 0, 0} pose:@"left side down"];
}

// The gyro mapping was right all along (the pointer worked while the accelerometer read zero);
// pin it so a later "fix" cannot move it. Rates follow the right-hand rule about the pad's axes,
// and the remote's frame is the pad's turned half a turn about the vertical.
- (void)testRotationRatesKeepTheirDirections
{
  _fixture.motion.rotationRate = (GCRotationRate){0.5, -0.25, 2.0};
  MFiController device((GCController*)(id)_fixture);
  const Common::Vec3 rates = RemoteAngularVelocity(device);
  XCTAssertEqualWithAccuracy(rates.x, -0.5, 1e-6, @"nose up is Pitch Up");
  XCTAssertEqualWithAccuracy(rates.y, 0.25, 1e-6, @"right side down is Roll Right");
  XCTAssertEqualWithAccuracy(rates.z, 2.0, 1e-6, @"turning left is Yaw Left");
}

// End to end through the core's own drift filter: the gyro pointer's orientation estimate for a
// pad held still with its nose 20 degrees up must stay the right way up, at that pitch.
- (void)testTheGyroPointerDoesNotSettleUpsideDown
{
  const double tilt = 20.0 * MathUtil::TAU / 360.0;
  _fixture.motion.acceleration = (GCAcceleration){0, -std::sin(tilt), -std::cos(tilt)};
  MFiController device((GCController*)(id)_fixture);
  const Common::Vec3 accel = RemoteAcceleration(device);

  auto rotation = Common::Quaternion::Identity();
  for (int step = 0; step != 2000; ++step)
    rotation = WiimoteEmu::ComplementaryFilter(rotation, accel, 0.02f).Normalized();

  const Common::Vec3 up = rotation * Common::Vec3{0, 0, 1};
  XCTAssertGreaterThan(up.z, 0.9f, @"the remote's top still faces up");
  XCTAssertEqualWithAccuracy(std::abs(WiimoteEmu::GetRoll(rotation)), 0.0, 1e-3);
  XCTAssertEqualWithAccuracy(std::abs(WiimoteEmu::GetPitch(rotation)), tilt, 1e-3);
}
@end
