// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "TVWiiSystemUpdateViewController.h"

#import "Core/WiiUtils.h"
#import "DiscIO/NANDImporter.h"
#import "FoundationStringUtil.h"
#import "LocalizationUtil.h"
#import <TargetConditionals.h>

@interface TVWiiSystemUpdateViewController ()

- (void)startUpdate;

@end

@implementation TVWiiSystemUpdateViewController {
	bool _hasStarted;
	bool _isCancelled;
	UIProgressView* _progressBar;
	UILabel* _statusLabel;
	UIButton* _cancelButton;
}

- (void)loadView {
	UIView* view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
	#if TARGET_OS_TV
	view.backgroundColor = UIColor.blackColor;
	#else
	view.backgroundColor = UIColor.systemBackgroundColor;
	#endif

	_progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
	_progressBar.translatesAutoresizingMaskIntoConstraints = NO;
	_progressBar.progress = 0.0f;

	_statusLabel = [UILabel new];
	_statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	_statusLabel.numberOfLines = 0;
	_statusLabel.textAlignment = NSTextAlignmentCenter;
	#if TARGET_OS_TV
	_statusLabel.textColor = UIColor.whiteColor;
	#else
	_statusLabel.textColor = UIColor.labelColor;
	#endif
	_statusLabel.text = DOLCoreLocalizedString(@"Preparing update…");

	_cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
	_cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
	[_cancelButton setTitle:DOLCoreLocalizedString(@"Cancel") forState:UIControlStateNormal];
	[_cancelButton addTarget:self action:@selector(cancelPressed:) forControlEvents:UIControlEventTouchUpInside];

	UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[_statusLabel, _progressBar, _cancelButton]];
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 24.0;

	[view addSubview:stack];
	[NSLayoutConstraint activateConstraints:@[
		[stack.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
		[stack.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
		[stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:view.layoutMarginsGuide.leadingAnchor],
		[stack.trailingAnchor constraintLessThanOrEqualToAnchor:view.layoutMarginsGuide.trailingAnchor],
		[_progressBar.widthAnchor constraintEqualToConstant:560.0]
	]];

	self.view = view;
}

- (void)viewDidAppear:(BOOL)animated {
	#if !TARGET_OS_TV
	[super viewDidAppear:animated];
	#endif
	// Auto-sleep off
	[[UIApplication sharedApplication] setIdleTimerDisabled:true];

	if (_hasStarted) {
		return;
	}
	_hasStarted = true;

	// If performing online update without a preset source, prompt for region first
	if (self.isOnlineUpdate && (self.updateSource.length == 0)) {
		UIAlertController* sheet = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(@"Select Region")
																							  message:nil
																				preferredStyle:UIAlertControllerStyleActionSheet];
		void (^pick)(NSString*) = ^(NSString* code){ self.updateSource = code; [self startUpdate]; };
		[sheet addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Europe") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* a){ pick(@"EUR"); }]];
		[sheet addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Japan") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* a){ pick(@"JPN"); }]];
		[sheet addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Korea") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* a){ pick(@"KOR"); }]];
		[sheet addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"United States") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* a){ pick(@"USA"); }]];
		[sheet addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"Cancel") style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction* a){ [self dismissViewControllerAnimated:true completion:nil]; }]];
		// iPad popover source
#if !TARGET_OS_TV
		UIPopoverPresentationController* pop = sheet.popoverPresentationController;
		if (pop) {
			pop.sourceView = self.view;
			CGRect r = self.view.bounds; r.origin.y = CGRectGetMaxY(r) - 1; r.size.height = 1;
			pop.sourceRect = r;
			pop.permittedArrowDirections = UIPopoverArrowDirectionDown;
		}
#endif
		[self presentViewController:sheet animated:true completion:nil];
		return;
	}

	[self startUpdate];
}

- (void)startUpdate {
	TVWiiSystemUpdateViewController* thisPtr = self;
	WiiUtils::UpdateCallback callback = [thisPtr](size_t processed, size_t total, u64 titleId) -> bool {
		__block bool cancelled = false;
		dispatch_sync(dispatch_get_main_queue(), ^{
			if (!thisPtr)
				return;
			cancelled = thisPtr->_isCancelled;
			if (!cancelled) {
				thisPtr->_progressBar.progress = (float)processed / (float)total;
				NSString* statusFormat = DOLCoreLocalizedStringWithArgs(@"Updating title %1...\nThis can take a while.", @"016llx");
				thisPtr->_statusLabel.text = [NSString stringWithFormat:statusFormat, titleId];
			}
		});
		return !cancelled;
	};

	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		WiiUtils::UpdateResult result;
		const std::string source = FoundationToCppString(self.updateSource ?: @"");
		if (self.isOnlineUpdate) {
			result = WiiUtils::DoOnlineUpdate(callback, source);
		} else {
			result = WiiUtils::DoDiscUpdate(callback, source);
		}
		if (result == WiiUtils::UpdateResult::Succeeded || result == WiiUtils::UpdateResult::AlreadyUpToDate) {
			DiscIO::NANDImporter().ExtractCertificates();
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[self handleResult:result];
		});
	});
}

- (void)viewWillDisappear:(BOOL)animated {
	[[UIApplication sharedApplication] setIdleTimerDisabled:false];
	#if !TARGET_OS_TV
	[super viewWillDisappear:animated];
	#endif
}

- (void)handleResult:(WiiUtils::UpdateResult)result {
	switch (result) {
		case WiiUtils::UpdateResult::Succeeded:
			[self showAlertWithTitle:@"Update completed" message:@"The emulated Wii console has been updated."];
			break;
		case WiiUtils::UpdateResult::AlreadyUpToDate:
			[self showAlertWithTitle:@"Update completed" message:@"The emulated Wii console is already up-to-date."];
			break;
		case WiiUtils::UpdateResult::ServerFailed:
			[self showAlertWithTitle:@"Update failed" message:@"Could not download update information from Nintendo. Please check your Internet connection and try again."];
			break;
		case WiiUtils::UpdateResult::DownloadFailed:
			[self showAlertWithTitle:@"Update failed" message:@"Could not download update files from Nintendo. Please check your Internet connection and try again."];
			break;
		case WiiUtils::UpdateResult::ImportFailed:
			[self showAlertWithTitle:@"Update failed" message:@"Could not install an update to the Wii system memory. Please refer to logs for more information."];
			break;
		case WiiUtils::UpdateResult::Cancelled:
			[self showAlertWithTitle:@"Update cancelled" message:@"The update has been cancelled. It is strongly recommended to finish it in order to avoid inconsistent system software versions."];
			break;
		case WiiUtils::UpdateResult::RegionMismatch:
			[self showAlertWithTitle:@"Update failed" message:@"The game's region does not match your console's. To avoid issues with the system menu, it is not possible to update the emulated console using this disc."];
			break;
		case WiiUtils::UpdateResult::MissingUpdatePartition:
		case WiiUtils::UpdateResult::DiscReadFailed:
			[self showAlertWithTitle:@"Update failed" message:@"The game disc does not contain any usable update information."];
			break;
		case WiiUtils::UpdateResult::NumberOfEntries:
			break;
	}
}

- (void)cancelPressed:(id)sender {
	_isCancelled = true;
	#if TARGET_OS_TV
	_progressBar.trackTintColor = UIColor.redColor;
	#else
	_progressBar.trackTintColor = UIColor.systemRedColor;
	#endif
	_progressBar.progress = 1.0f;
	_statusLabel.text = DOLCoreLocalizedString(@"Finishing the update...\nThis can take a while.");
	_cancelButton.enabled = false;
}

- (void)showAlertWithTitle:(NSString*)title message:(NSString*)message {
	UIAlertController* alert = [UIAlertController alertControllerWithTitle:DOLCoreLocalizedString(title)
																					message:DOLCoreLocalizedString(message)
															preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:DOLCoreLocalizedString(@"OK") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
		[self dismissViewControllerAnimated:true completion:nil];
	}]];
	[self presentViewController:alert animated:true completion:nil];
}

@end
