// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DSUPingBridge.h"

#import <Foundation/Foundation.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <fcntl.h>

// C++ DSU proto
#include "InputCommon/ControllerInterface/DualShockUDPClient/DualShockUDPClient.h"
#include "InputCommon/ControllerInterface/DualShockUDPClient/DualShockUDPProto.h"

namespace DSUPB = ciface::DualShockUDPClient::Proto;

@implementation DSUPingBridge

+ (void)pingServerAddress:(NSString *)address
                     port:(NSInteger)port
                  timeout:(NSTimeInterval)timeout
               completion:(void(^)(BOOL ok, NSString * _Nullable info))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    int sockfd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) { dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"socket() failed"); }); return; }

    // non-blocking
    int flags = fcntl(sockfd, F_GETFL, 0);
    fcntl(sockfd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in dst; memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons((uint16_t)(port > 0 ? port : 26760));
    if (inet_pton(AF_INET, address.UTF8String, &dst.sin_addr) != 1) {
      close(sockfd);
      dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"invalid address"); });
      return;
    }

    // Build VersionRequest
    DSUPB::Message<DSUPB::MessageType::VersionRequest> req(0);
    req.Finish();

    ssize_t sent = sendto(sockfd, &req.m_message, sizeof(req.m_message), 0, (const struct sockaddr*)&dst, sizeof(dst));
    if (sent <= 0) {
      close(sockfd);
      dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"send failed"); });
      return;
    }

    // Wait for response with simple poll loop
    const uint64_t deadline = (uint64_t)(timeout * 1000.0);
    uint8_t buf[1024];
    BOOL ok = NO;
    NSString* info = nil;

    for (uint64_t waited = 0; waited < deadline; waited += 10) {
      struct sockaddr_in src; socklen_t slen = sizeof(src);
      ssize_t n = recvfrom(sockfd, buf, sizeof(buf), 0, (struct sockaddr*)&src, &slen);
      if (n > 0) {
        // We don't parse fully; any packet back means the server is alive
        ok = YES;
        char abuf[INET_ADDRSTRLEN] = {0};
        const char* ip = inet_ntop(AF_INET, &src.sin_addr, abuf, sizeof(abuf));
        uint16_t p = ntohs(src.sin_port);
        if (ip) info = [NSString stringWithFormat:@"%s:%hu", ip, p];
        break;
      }
      // sleep 10ms
      struct timespec ts; ts.tv_sec = 0; ts.tv_nsec = 10 * 1000 * 1000; nanosleep(&ts, NULL);
    }

    close(sockfd);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, info); });
  });
}

@end
