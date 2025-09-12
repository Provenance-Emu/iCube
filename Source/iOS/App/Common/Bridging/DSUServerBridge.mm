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
  NSString* _lastError;
  NSUInteger _txCount;
  NSUInteger _rxCount;

  // last client target
  struct sockaddr_in _lastClient;
  socklen_t _lastClientLen;

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
+ (NSString*)ipAddress { return [[self shared] bestIPv4Address]; }

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
}

+ (void)setAxis:(NSInteger)axis controller:(NSInteger)controller value:(float)value {
  // Map to left/right sticks 0..255 and triggers
  auto clamp01 = [](float v) { if (v < 0.f) v = 0.f; if (v > 1.f) v = 1.f; return v; };
  auto& p = [self shared]->_pad;
  switch (axis) {
    case 0: p.left_stick_x = (uint8_t)lroundf(clamp01((value+1.f)/2.f)*255.f); break;
    case 1: p.left_stick_y_inverted = (uint8_t)lroundf(clamp01((1.f-value)/2.f)*255.f); break;
    case 2: p.right_stick_x = (uint8_t)lroundf(clamp01((value+1.f)/2.f)*255.f); break;
    case 3: p.right_stick_y_inverted = (uint8_t)lroundf(clamp01((1.f-value)/2.f)*255.f); break;
    case 4: p.trigger_l2 = (uint8_t)lroundf(clamp01((value+1.f)/2.f)*255.f); break;
    case 5: p.trigger_r2 = (uint8_t)lroundf(clamp01((value+1.f)/2.f)*255.f); break;
    default: break;
  }
}

- (instancetype)init {
  if (self = [super init]) {
    _running = NO; _sock = -1; _port = ciface::DualShockUDPClient::DEFAULT_SERVER_PORT;
    memset(&_lastClient, 0, sizeof(_lastClient)); _lastClientLen = sizeof(_lastClient);
    [self resetPad];
    _lastError = @"";
    _txCount = 0; _rxCount = 0;
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
      sendto(_sock, &resp.m_message, sizeof(resp.m_message), 0, (const struct sockaddr*)src, sizeof(*src));
      break;
    }
    case Proto::MessageType::ListPorts::TYPE: {
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
      // On request, respond immediately with a frame; regular frames are sent by timer
      [self sendPadDataTo:src];
      break;
    }
    default:
      break;
  }
}

- (void)sendPadData { if (_lastClientLen > 0) [self sendPadDataTo:&_lastClient]; }

- (void)sendPadDataTo:(const struct sockaddr_in*)dst {
  if (!_running || _sock < 0 || !dst) return;
  // Build response
  Proto::Message<Proto::MessageType::PadDataResponse> pd(0);
  pd.m_message = _pad; // copy
  pd.Finish();
  ssize_t sent = sendto(_sock, &pd.m_message, sizeof(pd.m_message), 0, (const struct sockaddr*)dst, sizeof(*dst));
  if (sent > 0) { _txCount++; }
}

- (void)publishBonjour {
  [_service stop]; _service = nil;
  // _dolphin-dsu._udp is custom; clients in our apps can browse this
  _service = [[NSNetService alloc] initWithDomain:@"local." type:@"_dolphin-dsu._udp" name:[[UIDevice currentDevice] name] port:_port];
  _service.delegate = self; [_service publishWithOptions:0];
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
