// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ICMacAppKitBridge.h"

#if TARGET_OS_MACCATALYST

#import <CoreGraphics/CoreGraphics.h>

// AppKit's headers cannot be imported into a Mac Catalyst target, so the methods used here are
// declared by hand and the classes are looked up by name. Everything named is public AppKit API.

@protocol ICNSImage <NSObject>
+ (nullable id<ICNSImage>)imageWithSystemSymbolName:(NSString*)name accessibilityDescription:(nullable NSString*)description;
- (void)setTemplate:(BOOL)isTemplate;
@end

@protocol ICNSMenuItem <NSObject>
+ (id<ICNSMenuItem>)separatorItem;
- (instancetype)initWithTitle:(NSString*)title action:(nullable SEL)action keyEquivalent:(NSString*)key;
- (void)setTarget:(nullable id)target;
- (void)setEnabled:(BOOL)enabled;
- (void)setState:(NSInteger)state;
- (void)setTag:(NSInteger)tag;
- (NSInteger)tag;
@end

@protocol ICNSMenu <NSObject>
- (instancetype)initWithTitle:(NSString*)title;
- (void)setAutoenablesItems:(BOOL)autoenables;
- (void)removeAllItems;
- (void)addItem:(id<ICNSMenuItem>)item;
@end

@protocol ICNSStatusBarButton <NSObject>
- (void)setImage:(nullable id<ICNSImage>)image;
- (void)setTitle:(NSString*)title;
- (void)setToolTip:(nullable NSString*)toolTip;
@end

@protocol ICNSStatusItem <NSObject>
- (nullable id<ICNSStatusBarButton>)button;
- (void)setMenu:(nullable id<ICNSMenu>)menu;
@end

@protocol ICNSStatusBar <NSObject>
+ (id<ICNSStatusBar>)systemStatusBar;
- (id<ICNSStatusItem>)statusItemWithLength:(CGFloat)length;
@end

@protocol ICNSApplication <NSObject>
+ (id<ICNSApplication>)sharedApplication;
- (void)activateIgnoringOtherApps:(BOOL)flag;
- (void)terminate:(nullable id)sender;
@end

// NSVariableStatusItemLength
static const CGFloat ICVariableStatusItemLength = -1.0;
// NSControlStateValueOn / NSControlStateValueOff
static const NSInteger ICControlStateOn = 1;
static const NSInteger ICControlStateOff = 0;

@implementation ICMacMenuEntry

- (instancetype)initWithTitle:(NSString*)title checked:(BOOL)checked separator:(BOOL)separator
                      handler:(nullable void (^)(void))handler {
  if ((self = [super init])) {
    _title = [title copy];
    _checked = checked;
    _separator = separator;
    _handler = [handler copy];
  }
  return self;
}

+ (instancetype)separatorEntry {
  return [[self alloc] initWithTitle:@"" checked:NO separator:YES handler:nil];
}

+ (instancetype)entryWithTitle:(NSString*)title checked:(BOOL)checked handler:(nullable void (^)(void))handler {
  return [[self alloc] initWithTitle:title checked:checked separator:NO handler:handler];
}

@end

@interface ICMacAppKitBridge ()
@property(nonatomic, strong, nullable) id<ICNSStatusItem> statusItem;
@property(nonatomic, strong, nullable) id<ICNSMenu> menu;
@property(nonatomic, copy) NSArray<ICMacMenuEntry*>* entries;
@end

@implementation ICMacAppKitBridge

+ (ICMacAppKitBridge*)shared {
  static ICMacAppKitBridge* shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [[ICMacAppKitBridge alloc] init];
    shared.entries = @[];
  });
  return shared;
}

+ (BOOL)installStatusItemWithSymbolName:(NSString*)symbolName toolTip:(NSString*)toolTip {
  ICMacAppKitBridge* bridge = [self shared];
  if (bridge.statusItem != nil) {
    return YES;
  }
  Class<ICNSStatusBar> statusBar = NSClassFromString(@"NSStatusBar");
  Class menuClass = NSClassFromString(@"NSMenu");
  if (statusBar == Nil || menuClass == Nil) {
    return NO;
  }
  id<ICNSStatusItem> item = [[statusBar systemStatusBar] statusItemWithLength:ICVariableStatusItemLength];
  if (item == nil) {
    return NO;
  }
  id<ICNSStatusBarButton> button = [item button];
  Class<ICNSImage> imageClass = NSClassFromString(@"NSImage");
  id<ICNSImage> image = [imageClass imageWithSystemSymbolName:symbolName accessibilityDescription:toolTip];
  if (image != nil) {
    // A template image follows the menu bar's light, dark and highlighted colours.
    [image setTemplate:YES];
    [button setImage:image];
  } else {
    [button setTitle:toolTip];
  }
  [button setToolTip:toolTip];

  id<ICNSMenu> menu = [(id<ICNSMenu>)[menuClass alloc] initWithTitle:toolTip];
  // Rows are enabled by whether they have a handler, not by AppKit's responder-chain validation.
  [menu setAutoenablesItems:NO];
  [item setMenu:menu];
  bridge.statusItem = item;
  bridge.menu = menu;
  [bridge rebuildMenu];
  return YES;
}

+ (void)setStatusMenuEntries:(NSArray<ICMacMenuEntry*>*)entries {
  ICMacAppKitBridge* bridge = [self shared];
  bridge.entries = entries;
  [bridge rebuildMenu];
}

- (void)rebuildMenu {
  if (self.menu == nil) {
    return;
  }
  Class<ICNSMenuItem> itemClass = NSClassFromString(@"NSMenuItem");
  [self.menu removeAllItems];
  [self.entries enumerateObjectsUsingBlock:^(ICMacMenuEntry* entry, NSUInteger index, BOOL* stop) {
    if (entry.isSeparator) {
      [self.menu addItem:[itemClass separatorItem]];
      return;
    }
    SEL action = entry.handler != nil ? @selector(menuItemChosen:) : NULL;
    id<ICNSMenuItem> item = [(id<ICNSMenuItem>)[(Class)itemClass alloc] initWithTitle:entry.title action:action keyEquivalent:@""];
    [item setTarget:entry.handler != nil ? self : nil];
    [item setEnabled:entry.handler != nil];
    [item setState:entry.checked ? ICControlStateOn : ICControlStateOff];
    [item setTag:(NSInteger)index];
    [self.menu addItem:item];
  }];
}

- (void)menuItemChosen:(id<ICNSMenuItem>)sender {
  NSInteger index = [sender tag];
  if (index < 0 || index >= (NSInteger)self.entries.count) {
    return;
  }
  void (^handler)(void) = self.entries[(NSUInteger)index].handler;
  if (handler != nil) {
    handler();
  }
}

+ (void)activateApp {
  Class<ICNSApplication> application = NSClassFromString(@"NSApplication");
  [[application sharedApplication] activateIgnoringOtherApps:YES];
}

+ (void)terminateApp {
  Class<ICNSApplication> application = NSClassFromString(@"NSApplication");
  [[application sharedApplication] terminate:nil];
}

@end

#endif
