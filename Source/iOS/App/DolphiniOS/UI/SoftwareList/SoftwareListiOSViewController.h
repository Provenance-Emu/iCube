// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "SoftwareListViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface SoftwareListiOSViewController : SoftwareListViewController
#if TARGET_OS_IOS
<UIDocumentPickerDelegate>
#endif

@end

NS_ASSUME_NONNULL_END
