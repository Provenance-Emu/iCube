// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import <XCTest/XCTest.h>
#import "../Common/UI/SoftwareList/GameFilePtrWrapper.h"
#import "../Common/UI/SoftwareList/TVGameItem.h"

/// A null core handle must still satisfy the model's nonnull Swift bridge.
@interface TVGameItemInvalidTests : XCTestCase
@end

@implementation TVGameItemInvalidTests
- (void)testEmptyCoreHandleKeepsOriginalFallbackAndSafeMetadataGetters {
    GameFilePtrWrapper *wrapper = [GameFilePtrWrapper new];
    TVGameItem *item = [[TVGameItem alloc] initWithWrapper:wrapper];
    XCTAssertNotNil(item.gameID);
    // Fail the invariant first, without crashing the baseline in Swift bridging.
    if (!item.gameID) return;
    XCTAssertNotNil(item.originalCoverImage);
    if (!item.originalCoverImage) return;
    XCTAssertEqualObjects(item.title, @"<null GameFile>");
    XCTAssertEqualObjects(item.filePath, @"<null>");
    XCTAssertEqualObjects(item.gameID, @"");
    XCTAssertEqualObjects(item.countryName, @"");
    XCTAssertEqualObjects(item.makerLong, @"");
    XCTAssertEqualObjects(item.gametdbID, @"");
    XCTAssertNotNil(item.coverImage);
    XCTAssertEqual(item.libraryTags.count, 0u);
    XCTAssertFalse(item.hasCoverArt);
}
@end
