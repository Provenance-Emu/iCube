// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DSUServerBridge.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>

// C++ headers (ObjC++)
// Logging category used by DSU proto
#include "Common/Logging/Log.h"
#include "InputCommon/ControllerInterface/DualShockUDPClient/DualShockUDPClient.h"
#include "InputCommon/ControllerInterface/DualShockUDPClient/DualShockUDPProto.h"
#include "Common/Hash.h"

using namespace ciface::DualShockUDPClient;
using ProtoFromClient = ciface::DualShockUDPClient::Proto::Message<ciface::DualShockUDPClient::Proto::MessageType::FromClient>;
using ProtoFromServer = ciface::DualShockUDPClient::Proto::Message<ciface::DualShockUDPClient::Proto::MessageType::FromServer>;

@interface DSUServerBridge () <NSNetServiceDelegate>
@end

@implementation DSUServerBridge {
  BOOL _running;
  int _sock;
  uint16_t _port;
  dispatch_source_t _recvSource;
  dispatch_source_t _tickSource;
  NSNetService* _service;
  NSDictionary<NSString*, NSData*>* _txt;
  NSString* _lastError;
  NSUInteger _txCount;
  NSUInteger _rxCount;

  // last client target
  struct sockaddr_in _lastClient;
  socklen_t _lastClientLen;

  // list of recent clients (address:port), newest first
  NSMutableArray<NSString*>* _clients;
  // optional restriction to a specific client address (address:port)
  NSString* _restrictTo;
  // approval required? if YES, only send to clients in _allowed
  BOOL _approvalRequired;
  // allowlist of clients (address:port)
  NSMutableSet<NSString*>* _allowed;
  // track prompted addresses to avoid spamming alerts
  NSMutableSet<NSString*>* _prompted;

  // simple pad state (pad 0)
  ciface::DualShockUDPClient::Proto::MessageType::PadDataResponse _pad;
}

+ (instancetype)shared { static DSUServerBridge* s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [DSUServerBridge new]; }); return s; }

+ (BOOL)startOnPort:(NSInteger)port { return [[self shared] start:(uint16_t)port]; }
+ (void)stop { [[self shared] stopImpl]; }
+ (BOOL)isRunning { return [[self shared] isRunningImpl]; }
+ (NSInteger)port { return [[self shared] currentPort]; }
+ (NSString *)lastError {
  DSUServerBridge* s = [self shared];
  return (s->_lastError && s->_lastError.length > 0) ? s->_lastError : @"";
}
+ (NSUInteger)txCount { return [self shared]->_txCount; }
+ (NSUInteger)rxCount { return [self shared]->_rxCount; }
// Return best-effort LAN IPv4 address for display/QR
+ (NSString*)ipAddress { return [[self shared] bestIPv4Address]; }
+ (NSArray<NSString*>*)clients {
  DSUServerBridge* s = [self shared];
  NSMutableArray<NSString*>* unique = [NSMutableArray array];
  NSMutableSet<NSString*>* seen = [NSMutableSet set];
  for (NSString* addr in s->_clients) {
    NSArray<NSString*>* parts = [addr componentsSeparatedByString:@":"]; if (parts.count < 1) continue;
    NSString* ip = parts[0]; if (ip.length == 0) continue;
    if (![seen containsObject:ip]) { [seen addObject:ip]; [unique addObject:ip]; }
  }
  return [unique copy];
}
+ (NSString * _Nullable)restrictedClient {
  return [self shared]->_restrictTo;
}
+ (void)setRestrictToClient:(NSString * _Nullable)addr {
  DSUServerBridge* s = [self shared];
  // Accept bare IPs from UI; treat empty as no restriction
  if (addr && addr.length > 0) {
    NSString* trimmed = [addr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    s->_restrictTo = trimmed;
  } else {
    s->_restrictTo = nil;
  }
}

+ (void)setApprovalRequired:(BOOL)required {
  DSUServerBridge* s = [self shared];
  s->_approvalRequired = required;
  [NSUserDefaults.standardUserDefaults setBool:required forKey:@"dsu_approval_required"];
}
+ (BOOL)approvalRequired { return [self shared]->_approvalRequired; }
+ (NSSet<NSString*>*)allowedClients { return [[self shared]->_allowed copy]; }
+ (void)setClient:(NSString*)addr allowed:(BOOL)allowed {
  if (addr.length == 0) return;
  DSUServerBridge* s = [self shared];
  // Normalize key to bare IP (ignore port) so approvals apply across ephemeral ports
  NSString* key = addr;
  NSRange colon = [key rangeOfString:@":"]; if (colon.location != NSNotFound) key = [key substringToIndex:colon.location];
  if (allowed) { [s->_allowed addObject:key]; }
  else { [s->_allowed removeObject:key]; }
  // Persist allowlist
  NSArray* arr = [s->_allowed allObjects];
  [NSUserDefaults.standardUserDefaults setObject:arr forKey:@"dsu_allowed_clients"];
}
+ (BOOL)isClientAllowed:(NSString*)addr {
  if (addr.length == 0) return NO;
  DSUServerBridge* s = [self shared];
  NSString* key = addr;
  NSRange colon = [key rangeOfString:@":"]; if (colon.location != NSNotFound) key = [key substringToIndex:colon.location];
  return [s->_allowed containsObject:key];
}
+ (BOOL)hasClient {
  DSUServerBridge* s = [self shared];
  return s->_lastClient.sin_port != 0;
}

+ (NSString*)lastClientAddress {
  DSUServerBridge* s = [self shared];
  if (s->_lastClient.sin_port == 0) return @"";
  char buf[INET_ADDRSTRLEN] = {0};
  const char* ip = inet_ntop(AF_INET, &s->_lastClient.sin_addr, buf, sizeof(buf));
  if (!ip) return @"";
  uint16_t port = ntohs(s->_lastClient.sin_port);
  return [NSString stringWithFormat:@"%s:%hu", ip, port];
}

+ (void)sendNow {
  [[self shared] sendPadData];
}

+ (void)setLayout:(NSString *)layout extension:(NSString * _Nullable)ext sideways:(BOOL)sideways {
  DSUServerBridge* s = [self shared];
  if (!layout) layout = @"unknown";
  NSMutableDictionary* txt = [NSMutableDictionary dictionaryWithDictionary:s->_txt ?: @{}];
  txt[@"layout"] = [layout dataUsingEncoding:NSUTF8StringEncoding];
  if (ext && ext.length > 0) txt[@"ext"] = [ext dataUsingEncoding:NSUTF8StringEncoding]; else [txt removeObjectForKey:@"ext"];
  txt[@"sideways"] = [[NSString stringWithFormat:@"%d", sideways ? 1 : 0] dataUsingEncoding:NSUTF8StringEncoding];
  s->_txt = [txt copy];
  if (s->_service) { [s->_service setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:s->_txt]]; }
}

+ (void)setButton:(NSInteger)button controller:(NSInteger)controller state:(BOOL)state {
  // Map generic buttons to DSU bitfields roughly (PS layout)
  auto& b1 = [self shared]->_pad.button_states1;
  auto& b2 = [self shared]->_pad.button_states2;
  uint8_t mask = 0;
  switch (button) {
    case 0: mask = 0x10; break; // Square
    case 1: mask = 0x20; break; // Cross
    case 2: mask = 0x40; break; // Circle
    case 3: mask = 0x80; break; // Triangle
    default: break;
  }
  if (mask) { if (state) b1 |= mask; else b1 &= ~mask; }
  // Also drive analog values for face buttons some clients rely on
  auto& p = [self shared]->_pad;
  uint8_t val = state ? 255 : 0;
  switch (button) {
    case 0: p.button_square_analog = val; break;
    case 1: p.button_cross_analog = val; break;
    case 2: p.button_circle_analog = val; break;
    case 3: p.button_triangle_analog = val; break;
    default: break;
  }
  // Push an immediate frame so clients react without waiting for the tick
  [[self shared] sendPadData];
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    NSLog(@"[DSU] setButton idx=%ld state=%d -> b1=%02x b2=%02x", (long)button, state, b1, b2);
  }
}

+ (void)setAxis:(NSInteger)axis controller:(NSInteger)controller value:(float)value {
  // Map to left/right sticks 0..255 and triggers
  // DSU protocol: X-axis: 0=left, 128=center, 255=right
  //               Y-axis: 0=up, 128=center, 255=down (hence "y_inverted" field names)
  // Input value range: [-1, +1] where -1=left/up, 0=center, +1=right/down
  auto clamp01 = [](float v) { if (v < 0.f) v = 0.f; if (v > 1.f) v = 1.f; return v; };
  auto& p = [self shared]->_pad;
  switch (axis) {
    case 0: p.left_stick_x = (uint8_t)lroundf(clamp01((value+1.f)/2.f)*255.f); break;
    case 1: p.left_stick_y_inverted = (uint8_t)lroundf(clamp01((value+1.f)/2.f)*255.f); break;
    case 2: p.right_stick_x = (uint8_t)lroundf(clamp01((value+1.f)/2.f)*255.f); break;
    case 3: p.right_stick_y_inverted = (uint8_t)lroundf(clamp01((value+1.f)/2.f)*255.f); break;
    case 4: p.trigger_l2 = (uint8_t)lroundf(clamp01((value+1.f)/2.f)*255.f); break;
    case 5: p.trigger_r2 = (uint8_t)lroundf(clamp01((value+1.f)/2.f)*255.f); break;
    default: break;
  }
  // Push an immediate frame so clients react without waiting for the tick
  [[self shared] sendPadData];
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    NSLog(@"[DSU] setAxis idx=%ld value=%.3f -> LX=%u LY=%u RX=%u RY=%u L2=%u R2=%u",
          (long)axis, value, p.left_stick_x, p.left_stick_y_inverted,
          p.right_stick_x, p.right_stick_y_inverted, p.trigger_l2, p.trigger_r2);
  }
}

+ (void)setDPadUpForController:(NSInteger)controller state:(BOOL)state {
  auto& p = [self shared]->_pad;
  p.button_dpad_up_analog = state ? 255 : 0;
  [[self shared] sendPadData];
}

+ (void)setDPadDownForController:(NSInteger)controller state:(BOOL)state {
  auto& p = [self shared]->_pad;
  p.button_dpad_down_analog = state ? 255 : 0;
  [[self shared] sendPadData];
}

+ (void)setDPadLeftForController:(NSInteger)controller state:(BOOL)state {
  auto& p = [self shared]->_pad;
  p.button_dpad_left_analog = state ? 255 : 0;
  [[self shared] sendPadData];
}

+ (void)setDPadRightForController:(NSInteger)controller state:(BOOL)state {
  auto& p = [self shared]->_pad;
  p.button_dpad_right_analog = state ? 255 : 0;
  [[self shared] sendPadData];
}

+ (void)setShoulderL:(NSInteger)controller state:(BOOL)state {
  auto& p = [self shared]->_pad;
  p.button_l1_analog = state ? 255 : 0;
  [[self shared] sendPadData];
}
+ (void)setShoulderR:(NSInteger)controller state:(BOOL)state {
  auto& p = [self shared]->_pad;
  p.button_r1_analog = state ? 255 : 0;
  [[self shared] sendPadData];
}

+ (void)setShare:(NSInteger)controller state:(BOOL)state {
  auto& b1 = [self shared]->_pad.button_states1;
  if (state) b1 |= 0x1; else b1 &= ~0x1;
  [[self shared] sendPadData];
}
+ (void)setOptions:(NSInteger)controller state:(BOOL)state {
  auto& b1 = [self shared]->_pad.button_states1;
  if (state) b1 |= 0x8; else b1 &= ~0x8;
  [[self shared] sendPadData];
}
+ (void)setPS:(NSInteger)controller state:(BOOL)state {
  auto& ps = [self shared]->_pad.button_ps;
  ps = state ? 1 : 0;
  [[self shared] sendPadData];
}
+ (void)setTouch:(NSInteger)controller state:(BOOL)state {
  auto& touch = [self shared]->_pad.button_touch;
  touch = state ? 1 : 0;
  [[self shared] sendPadData];
}

+ (void)setTouchPoint:(NSInteger)touchId controller:(NSInteger)controller active:(BOOL)active x:(NSInteger)x y:(NSInteger)y {
  auto& p = [self shared]->_pad;
  if (touchId == 0) {
    p.touch1.active = active ? 1 : 0;
    p.touch1.id = (u8)touchId;
    p.touch1.x = (s16)x;
    p.touch1.y = (s16)y;
  } else if (touchId == 1) {
    p.touch2.active = active ? 1 : 0;
    p.touch2.id = (u8)touchId;
    p.touch2.x = (s16)x;
    p.touch2.y = (s16)y;
  }
  [[self shared] sendPadData];
}

- (instancetype)init {
  if (self = [super init]) {
    _running = NO; _sock = -1; _port = ciface::DualShockUDPClient::DEFAULT_SERVER_PORT;
    memset(&_lastClient, 0, sizeof(_lastClient)); _lastClientLen = sizeof(_lastClient);
    [self resetPad];
    _lastError = @"";
    _txCount = 0; _rxCount = 0;
    _clients = [NSMutableArray array];
    _restrictTo = nil;
    // Load persisted approval state & allowlist
    NSUserDefaults* defs = NSUserDefaults.standardUserDefaults;
    // Default OFF if not set
    if ([defs objectForKey:@"dsu_approval_required"] == nil) { [defs setBool:NO forKey:@"dsu_approval_required"]; }
    _approvalRequired = [defs boolForKey:@"dsu_approval_required"];
    _allowed = [NSMutableSet set];
    NSArray* persisted = [defs arrayForKey:@"dsu_allowed_clients"];
    if ([persisted isKindOfClass:[NSArray class]]) {
      for (id item in persisted) {
        if ([item isKindOfClass:[NSString class]]) {
          NSString* s = (NSString*)item;
          // Normalize any legacy entries saved as "ip:port" to bare IP
          NSRange c = [s rangeOfString:@":"]; if (c.location != NSNotFound) s = [s substringToIndex:c.location];
          if (s.length > 0) { [_allowed addObject:s]; }
        }
      }
      // Write back normalized list
      [defs setObject:[_allowed allObjects] forKey:@"dsu_allowed_clients"];
    }
    _prompted = [NSMutableSet set];
  }
  return self;
}

- (void)resetPad {
  memset(&_pad, 0, sizeof(_pad));
  _pad.pad_id = 0;
  _pad.pad_state = ciface::DualShockUDPClient::Proto::DsState::Connected;
  _pad.model = ciface::DualShockUDPClient::Proto::DsModel::FullGyro;
  _pad.connection_type = ciface::DualShockUDPClient::Proto::DsConnection::Bluetooth;
  _pad.battery_status = ciface::DualShockUDPClient::Proto::DsBattery::Full;
  _pad.left_stick_x = 128; _pad.left_stick_y_inverted = 128;
  _pad.right_stick_x = 128; _pad.right_stick_y_inverted = 128;
  _pad.touch1.active = 0; _pad.touch1.id = 0; _pad.touch1.x = 0; _pad.touch1.y = 0;
  // Mark frames as active and start packet counter at 0
  _pad.active = 1;
  _pad.hid_packet_counter = 0;
}

- (BOOL)isRunningImpl { return _running; }
- (NSInteger)currentPort { return _port; }

- (BOOL)start:(uint16_t)port {
  if (_running) return YES;
  _port = port ? port : ciface::DualShockUDPClient::DEFAULT_SERVER_PORT;

  _sock = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (_sock < 0) { _lastError = @"Socket creation failed"; return NO; }

  int yes = 1; setsockopt(_sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_ANY); addr.sin_port = htons(_port);
  if (bind(_sock, (struct sockaddr*)&addr, sizeof(addr)) != 0) { _lastError = @"Bind failed (port in use or restricted)"; close(_sock); _sock = -1; return NO; }

  _running = YES;
  _lastError = @"";
  [self publishBonjour];
  [self setupReceive];
  [self setupTick];
  return YES;
}

- (void)stopImpl {
  if (!_running) return;
  _running = NO;
  if (_recvSource) { dispatch_source_cancel(_recvSource); _recvSource = nil; }
  if (_tickSource) { dispatch_source_cancel(_tickSource); _tickSource = nil; }
  if (_sock >= 0) { close(_sock); _sock = -1; }
  [_service stop]; _service = nil;
}

- (void)setupReceive {
  _recvSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _sock, 0, dispatch_get_main_queue());
  __weak DSUServerBridge* weakSelf = self;
  dispatch_source_set_event_handler(_recvSource, ^{
    DSUServerBridge* selfRef = weakSelf; if (!selfRef) return;
    struct sockaddr_in src; socklen_t slen = sizeof(src);
    uint8_t buf[1024]; ssize_t n = recvfrom(selfRef->_sock, buf, sizeof(buf), 0, (struct sockaddr*)&src, &slen);
    if (n <= 0) return;
    selfRef->_lastClient = src; selfRef->_lastClientLen = slen;
    selfRef->_rxCount++;
    // Track client list (address:port), newest first, unique
    char abuf[INET_ADDRSTRLEN] = {0};
    const char* ip = inet_ntop(AF_INET, &src.sin_addr, abuf, sizeof(abuf));
    if (ip) {
      uint16_t prt = ntohs(src.sin_port);
      NSString* addr = [NSString stringWithFormat:@"%s:%hu", ip, prt];
      NSString* keyIP = [NSString stringWithUTF8String:ip];
      BOOL wasPresent = [selfRef->_clients containsObject:addr];
      // Remove existing occurrence
      [selfRef->_clients removeObject:addr];
      // Insert at front
      [selfRef->_clients insertObject:addr atIndex:0];
      // Cap list size
      if (selfRef->_clients.count > 8) { [selfRef->_clients removeLastObject]; }
      // If approval required and not allowed and newly seen (by IP), post approval prompt once (by IP)
      if (selfRef->_approvalRequired && ![selfRef->_allowed containsObject:keyIP] && ![selfRef->_prompted containsObject:keyIP]) {
        [selfRef->_prompted addObject:keyIP];
        dispatch_async(dispatch_get_main_queue(), ^{
          [[NSNotificationCenter defaultCenter] postNotificationName:@"DSUNewClientApproval" object:nil userInfo:@{ @"address": addr }];
        });
      }
    }
    [selfRef handlePacket:buf length:(size_t)n from:&src];
  });
  dispatch_resume(_recvSource);
}

- (void)setupTick {
  _tickSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(_tickSource, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(NSEC_PER_SEC/60), NSEC_PER_MSEC*2);
  __weak DSUServerBridge* weakSelf = self;
  dispatch_source_set_event_handler(_tickSource, ^{ DSUServerBridge* s = weakSelf; if (!s) return; [s sendPadData]; });
  dispatch_resume(_tickSource);
}

- (void)handlePacket:(const void*)data length:(size_t)len from:(const struct sockaddr_in*)src {
  if (len < sizeof(Proto::MessageType::FromClient)) return;
  Proto::MessageType::FromClient msg{};
  memcpy(&msg, data, MIN(len, sizeof(msg)));
  // Quick filter by protocol magic
  if (msg.header.source != Proto::CLIENT) return;
  switch (msg.message_type) {
    case Proto::MessageType::VersionRequest::TYPE: {
      Proto::Message<Proto::MessageType::VersionResponse> resp(0);
      resp.m_message.max_protocol_version = Proto::CEMUHOOK_PROTOCOL_VERSION;
      resp.Finish();
      // Always allow VersionResponse so clients can detect us
      sendto(_sock, &resp.m_message, sizeof(resp.m_message), 0, (const struct sockaddr*)src, sizeof(*src));
      break;
    }
    case Proto::MessageType::ListPorts::TYPE: {
      // If approval required, only advertise ports to allowed clients
      if (_approvalRequired) {
        char buf[INET_ADDRSTRLEN] = {0};
        const char* ip = inet_ntop(AF_INET, &src->sin_addr, buf, sizeof(buf));
        NSString* key = ip ? [NSString stringWithUTF8String:ip] : @"";
        if (![_allowed containsObject:key]) break;
      }
      // advertise only pad 0
      Proto::Message<Proto::MessageType::PortInfo> pi(0);
      pi.m_message.pad_id = 0;
      pi.m_message.pad_state = Proto::DsState::Connected;
      pi.m_message.model = Proto::DsModel::FullGyro;
      pi.m_message.connection_type = Proto::DsConnection::Bluetooth;
      memset(pi.m_message.pad_mac_address.data(), 0, pi.m_message.pad_mac_address.size());
      pi.m_message.battery_status = Proto::DsBattery::Full;
      pi.Finish();
      sendto(_sock, &pi.m_message, sizeof(pi.m_message), 0, (const struct sockaddr*)src, sizeof(*src));
      break;
    }
    case Proto::MessageType::PadDataRequest::TYPE: {
      // Only respond if allowed (or approval not required)
      if (_approvalRequired) {
        char buf[INET_ADDRSTRLEN] = {0};
        const char* ip = inet_ntop(AF_INET, &src->sin_addr, buf, sizeof(buf));
        NSString* key = ip ? [NSString stringWithUTF8String:ip] : @"";
        if (![_allowed containsObject:key]) break;
      }
      // On request, respond immediately with a frame; regular frames are sent by timer
      [self sendPadDataTo:src];
      break;
    }
    default:
      break;
  }
}

- (void)sendPadData {
  // If restricted, send only to last client seen (if any)
  if (_restrictTo && _restrictTo.length > 0) {
    // Send to all recently seen ports for the restricted IP
    NSString* rest = _restrictTo;
    NSRange c = [rest rangeOfString:@":"]; if (c.location != NSNotFound) rest = [rest substringToIndex:c.location];
    for (NSString* addr in _clients) {
      NSArray<NSString*>* parts = [addr componentsSeparatedByString:@":"]; if (parts.count != 2) continue;
      if (![parts[0] isEqualToString:rest]) continue;
      const char* ip = [parts[0] UTF8String];
      int prt = parts[1].intValue; if (prt <= 0 || prt > 65535) continue;
      struct sockaddr_in dst; memset(&dst, 0, sizeof(dst));
      dst.sin_family = AF_INET; dst.sin_port = htons((uint16_t)prt);
      if (inet_pton(AF_INET, ip, &dst.sin_addr) != 1) continue;
      [self sendPadDataTo:&dst];
    }
    return;
  }
  // Broadcast to all recently seen clients when not restricted
  for (NSString* addr in _clients) {
    NSArray<NSString*>* parts = [addr componentsSeparatedByString:@":"];
    if (parts.count != 2) continue;
    const char* ip = [parts[0] UTF8String];
    int prt = parts[1].intValue; if (prt <= 0 || prt > 65535) continue;
    struct sockaddr_in dst; memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons((uint16_t)prt);
    if (inet_pton(AF_INET, ip, &dst.sin_addr) != 1) continue;
    [self sendPadDataTo:&dst];
  }
}

- (void)sendPadDataTo:(const struct sockaddr_in*)dst {
  if (!_running || _sock < 0 || !dst) return;
  // If restricting to a specific client, ensure this destination matches
  if (_restrictTo && _restrictTo.length > 0) {
    char buf[INET_ADDRSTRLEN] = {0};
    const char* ip = inet_ntop(AF_INET, &dst->sin_addr, buf, sizeof(buf));
    if (ip) {
      // Accept match by IP only, ignoring destination port to handle ephemeral client ports
      NSString* curIP = [NSString stringWithUTF8String:ip];
      NSString* rest = _restrictTo;
      NSRange c = [rest rangeOfString:@":"]; if (c.location != NSNotFound) rest = [rest substringToIndex:c.location];
      if (![curIP isEqualToString:rest]) return;
    }
  }
  // If approval required, only send to allowed clients
  if (_approvalRequired) {
    char buf2[INET_ADDRSTRLEN] = {0};
    const char* ip2 = inet_ntop(AF_INET, &dst->sin_addr, buf2, sizeof(buf2));
    NSString* key2 = ip2 ? [NSString stringWithUTF8String:ip2] : @"";
    if (![_allowed containsObject:key2]) return;
  }
  // Build response
  // Increment packet counter per send so clients see changing HID counter
  _pad.hid_packet_counter++;
  Proto::Message<Proto::MessageType::PadDataResponse> pd(0);
  // Preserve header and message_type initialized by constructor; copy only payload after message_type
  size_t header_and_type_size = sizeof(pd.m_message.header) + sizeof(pd.m_message.message_type);
  memcpy((uint8_t*)&pd.m_message + header_and_type_size,
         (const uint8_t*)&_pad + header_and_type_size,
         sizeof(pd.m_message) - header_and_type_size);
  pd.Finish();
  ssize_t sent = sendto(_sock, &pd.m_message, sizeof(pd.m_message), 0, (const struct sockaddr*)dst, sizeof(*dst));
  if (sent > 0) { _txCount++; }
  // Debug logging
  if ([[NSUserDefaults standardUserDefaults] boolForKey:@"input_debug"]) {
    char ipbuf[INET_ADDRSTRLEN] = {0};
    const char* ip = inet_ntop(AF_INET, &dst->sin_addr, ipbuf, sizeof(ipbuf));
    uint16_t p = ntohs(dst->sin_port);
    NSLog(@"[DSU] Sent PadDataResponse %zd bytes to %s:%hu hid_counter=%u buttons1=%02x buttons2=%02x L2=%u R2=%u",
          sent, ip ? ip : "<unknown>", p, pd.m_message.hid_packet_counter,
          pd.m_message.button_states1, pd.m_message.button_states2,
          pd.m_message.trigger_l2, pd.m_message.trigger_r2);
  }
}

- (void)publishBonjour {
  [_service stop]; _service = nil;
  // _dolphin-dsu._udp is custom; clients in our apps can browse this
  _service = [[NSNetService alloc] initWithDomain:@"local." type:@"_dolphin-dsu._udp" name:[[UIDevice currentDevice] name] port:_port];
  _service.delegate = self; [_service publishWithOptions:0];
  if (_txt) { [_service setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:_txt]]; }
}

- (NSString*)bestIPv4Address {
  struct ifaddrs* ifaddr = NULL; if (getifaddrs(&ifaddr) != 0) return @"";
  NSString* result = @"";
  for (struct ifaddrs* ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
    if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_addr->sa_family != AF_INET)) continue;
    struct sockaddr_in* sa = (struct sockaddr_in*)ifa->ifa_addr;
    char buf[INET_ADDRSTRLEN]; const char* s = inet_ntop(AF_INET, &sa->sin_addr, buf, sizeof(buf));
    if (s) { result = [NSString stringWithUTF8String:s]; if (strcmp(ifa->ifa_name, "en0") == 0) break; }
  }
  freeifaddrs(ifaddr);
  return result;
}

@end
