// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Which emulated controller a control group belongs to: the same four owners as Swift's
/// `RemapGroupOwner`. `group` is then a raw `PadGroup` (GCPadEmu.h), `WiimoteEmu::WiimoteGroup`
/// (WiimoteEmu.h), `WiimoteEmu::NunchukGroup` (Nunchuk.h) or `WiimoteEmu::ClassicGroup` (Classic.h).
typedef NS_ENUM(NSInteger, DOLControlGroupOwner) {
  DOLControlGroupOwnerGCPad = 0,
  DOLControlGroupOwnerWiimote = 1,
  DOLControlGroupOwnerNunchuk = 2,
  DOLControlGroupOwnerClassic = 3,
} NS_SWIFT_NAME(ControlGroupOwner);

/// `ciface::ExpressionParser::ParseStatus` (ExpressionParser.h).
typedef NS_ENUM(NSInteger, DOLExpressionStatus) {
  DOLExpressionStatusSuccessful = 0,
  DOLExpressionStatusSyntaxError = 1,
  DOLExpressionStatusEmpty = 2,
} NS_SWIFT_NAME(ExpressionParseStatus);

/// `ControllerEmu::SettingType` (NumericSetting.h).
typedef NS_ENUM(NSInteger, DOLNumericSettingType) {
  DOLNumericSettingTypeInt = 0,
  DOLNumericSettingTypeDouble = 1,
  DOLNumericSettingTypeBool = 2,
} NS_SWIFT_NAME(NumericSettingType);

NS_SWIFT_NAME(ExpressionParseResult)
@interface DOLExpressionParseResult : NSObject
@property (nonatomic, readonly) DOLExpressionStatus status;
/// The parser's (translated) explanation of a syntax error; nil otherwise.
@property (nonatomic, readonly, copy, nullable) NSString* message;
@end

/// One `ControllerEmu::NumericSetting` of a control group, as plain values. Bool settings report
/// 0/1 with a 0...1 range.
NS_SWIFT_NAME(NumericSettingInfo)
@interface DOLNumericSettingInfo : NSObject
/// Position in the group's `numeric_settings`: what `setNumericSetting…` takes.
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy) NSString* name;
/// Unit shown after the value ("%", "°", "cm"); empty when none.
@property (nonatomic, readonly, copy) NSString* suffix;
@property (nonatomic, readonly) DOLNumericSettingType type;
@property (nonatomic, readonly) double value;
@property (nonatomic, readonly) double minimum;
@property (nonatomic, readonly) double maximum;
@property (nonatomic, readonly) double defaultValue;
/// The value is driven by an expression, not a plain number; the player screen shows it read-only.
@property (nonatomic, readonly) BOOL isExpression;
@end

/// The player screen's Advanced section: Dolphin's expression parser, used as a check that installs
/// nothing, and the numeric settings (dead zones, gate sizes, IR and IMU values) of a control group.
/// App-side only: every call is to a symbol the core library already exports.
@interface DOLControllerSettingsBridge : NSObject

/// Parses `expression` with `ciface::ExpressionParser::ParseExpression`, the parser
/// `ControlReference::SetExpression` runs, WITHOUT installing it. `SetExpression` installs a text
/// that does not parse and only returns the error, which the mapping bridge discards.
+ (DOLExpressionParseResult*)parseExpression:(NSString*)expression NS_SWIFT_NAME(parse(expression:));

/// Every numeric setting of one group of one port (1-based), in the group's order. Empty when the
/// controller config is not loaded.
+ (NSArray<DOLNumericSettingInfo*>*)numericSettingsForOwner:(DOLControlGroupOwner)owner
                                                       port:(NSInteger)portOneBased
                                                      group:(NSInteger)groupId
    NS_SWIFT_NAME(numericSettings(owner:port:group:));

/// Sets one setting (clamped to its range; bools read non-zero as true), replacing any expression
/// that drove it, and saves the controller config.
+ (void)setNumericSettingValue:(double)value
                         index:(NSInteger)settingIndex
                         owner:(DOLControlGroupOwner)owner
                          port:(NSInteger)portOneBased
                         group:(NSInteger)groupId
    NS_SWIFT_NAME(setNumericSetting(_:index:owner:port:group:));

/// A group's "Enabled" setting (`ControlGroup::enabled`), for groups that have one (the Wii Remote's
/// IMU pointer). NO when the group has none.
+ (BOOL)isGroupEnabledForOwner:(DOLControlGroupOwner)owner
                          port:(NSInteger)portOneBased
                         group:(NSInteger)groupId
    NS_SWIFT_NAME(isGroupEnabled(owner:port:group:));

+ (void)setGroupEnabled:(BOOL)enabled
                  owner:(DOLControlGroupOwner)owner
                   port:(NSInteger)portOneBased
                  group:(NSInteger)groupId
    NS_SWIFT_NAME(setGroupEnabled(_:owner:port:group:));

@end

NS_ASSUME_NONNULL_END
