// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <gtest/gtest.h>

#include "DiscIO/RemoteCacheSourceID.h"

using DiscIO::RemoteCacheSourceID;

// IDs must match WebDAVSource.generateConsistentId (Swift): URL.host, then URL.port or the scheme
// default, with '.' and ':' replaced by '_'.

TEST(RemoteCacheSourceID, HostAndExplicitPort)
{
  EXPECT_EQ(RemoteCacheSourceID("http://nas.local:8080/games/a.iso"), "nas_local_8080");
}

TEST(RemoteCacheSourceID, SchemeDefaultPorts)
{
  EXPECT_EQ(RemoteCacheSourceID("http://nas/a.iso"), "nas_80");
  EXPECT_EQ(RemoteCacheSourceID("https://example.com/a.iso"), "example_com_443");
}

TEST(RemoteCacheSourceID, NotAUrl)
{
  EXPECT_EQ(RemoteCacheSourceID("nas/a.iso"), "");
}

// Sentry ICUBE-87: std::stoi on the text after the first ':' threw "stoi: no conversion" for these,
// uncaught on the library scan's queue, so every launch crashed while such a source existed.

TEST(RemoteCacheSourceID, CredentialsAreNotPartOfTheHost)
{
  EXPECT_EQ(RemoteCacheSourceID("http://user:pass@nas:5005/a.iso"), "nas_5005");
  EXPECT_EQ(RemoteCacheSourceID("https://user:pass@nas/a.iso"), "nas_443");
}

TEST(RemoteCacheSourceID, BracketedIPv6Host)
{
  EXPECT_EQ(RemoteCacheSourceID("http://[fe80::1]:8080/a.iso"), "fe80__1_8080");
  EXPECT_EQ(RemoteCacheSourceID("http://[fe80::1]/a.iso"), "fe80__1_80");
}

TEST(RemoteCacheSourceID, UnparsablePortFallsBackToTheSchemeDefault)
{
  EXPECT_EQ(RemoteCacheSourceID("http://nas:notaport/a.iso"), "nas_80");
  EXPECT_EQ(RemoteCacheSourceID("http://nas:/a.iso"), "nas_80");
  EXPECT_EQ(RemoteCacheSourceID("http://nas:99999999999999999999/a.iso"), "nas_80");
}
