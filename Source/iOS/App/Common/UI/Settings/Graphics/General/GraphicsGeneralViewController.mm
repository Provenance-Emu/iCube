// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "GraphicsGeneralViewController.h"

#import "Core/Config/GraphicsSettings.h"
#import "Core/Config/MainSettings.h"

#import "VideoCommon/VideoBackendBase.h"
#import "VideoCommon/VideoConfig.h"

#import "FoundationStringUtil.h"
#import "LocalizationUtil.h"

@interface GraphicsGeneralViewController ()

@end

@implementation GraphicsGeneralViewController

- (void)viewDidLoad {
  [super viewDidLoad];

  [self.aspectRatioCell registerSetting:Config::GFX_ASPECT_RATIO];
  [self.vsyncCell registerSetting:Config::GFX_VSYNC];
  [self.autoIrEnableCell registerSetting:Config::GFX_AUTO_IR_ENABLE];
  [self.autoIrOsdCell registerSetting:Config::GFX_AUTO_IR_SHOW_OSD];
  [self.autoIrTargetFpsCell registerSetting:Config::GFX_AUTO_IR_TARGET_FPS];
  [self.autoIrMinScaleCell registerSetting:Config::GFX_AUTO_IR_MIN_SCALE];
  [self.autoIrMaxScaleCell registerSetting:Config::GFX_AUTO_IR_MAX_SCALE];
  [self.shaderModeCell registerSetting:Config::GFX_SHADER_COMPILATION_MODE];
  [self.shaderCompileCell registerSetting:Config::GFX_WAIT_FOR_SHADERS_BEFORE_STARTING];

  // Triple buffering toggle (NSUserDefaults-backed UI)
  self.tripleBufferCell.boolLabel.text = @"Triple Buffering";
  BOOL triple = [NSUserDefaults.standardUserDefaults objectForKey:@"gfx_triple_buffering"] ? [NSUserDefaults.standardUserDefaults boolForKey:@"gfx_triple_buffering"] : YES;
  self.tripleBufferCell.boolSwitch.on = triple;
  [self.tripleBufferCell.boolSwitch addValueChangedTarget:self action:@selector(tripleBufferingChanged:)];

  // Force scale 1.0 on non-ProMotion
  self.forceScaleOneCell.boolLabel.text = @"Force scale 1.0 on non‑ProMotion";
  BOOL forceScaleOne = [NSUserDefaults.standardUserDefaults boolForKey:@"gfx_force_scale_one_non_promo"];
  self.forceScaleOneCell.boolSwitch.on = forceScaleOne;
  [self.forceScaleOneCell.boolSwitch addValueChangedTarget:self action:@selector(forceScaleOneChanged:)];

  // Async Present (avoid blocking waits on present/submit)
  self.asyncPresentCell.boolLabel.text = @"Asynchronous Present";
  self.asyncPresentCell.boolSwitch.on = Config::Get(Config::GFX_ASYNC_PRESENT);
  [self.asyncPresentCell.boolSwitch addValueChangedTarget:self action:@selector(asyncPresentChanged:)];
}

- (void)tripleBufferingChanged:(id)sender {
  [NSUserDefaults.standardUserDefaults setBool:self.tripleBufferCell.boolSwitch.on forKey:@"gfx_triple_buffering"];
}

- (void)forceScaleOneChanged:(id)sender {
  [NSUserDefaults.standardUserDefaults setBool:self.forceScaleOneCell.boolSwitch.on forKey:@"gfx_force_scale_one_non_promo"];
}

- (void)asyncPresentChanged:(id)sender {
  Config::SetBaseOrCurrent(Config::GFX_ASYNC_PRESENT, self.asyncPresentCell.boolSwitch.on);
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  std::string currentBackend = Config::Get(Config::MAIN_GFX_BACKEND);

  NSString* localizableBackend = nil;
  for (auto& backend : VideoBackendBase::GetAvailableBackends()) {
    if (currentBackend == backend->GetName()) {
      localizableBackend = CppToFoundationString(backend->GetDisplayName());
      break;
    }
  }

  if (localizableBackend != nil) {
    self.backendLabel.text = DOLCoreLocalizedString(localizableBackend);
  } else {
    self.backendLabel.text = CppToFoundationString(currentBackend);
  }

  NSString* aspectRatio;
  switch (Config::Get(Config::GFX_ASPECT_RATIO)) {
    case AspectMode::Auto:
      aspectRatio = @"Auto";
      break;
    case AspectMode::ForceStandard:
      aspectRatio = @"Force 4:3";
      break;
    case AspectMode::ForceWide:
      aspectRatio = @"Force 16:9";
      break;
    case AspectMode::Stretch:
      aspectRatio = @"Stretch to Window";
      break;
    default:
      aspectRatio = @"Error";
      break;
  }

  self.aspectRatioCell.choiceSettingLabel.text = DOLCoreLocalizedString(aspectRatio);

  NSString* shaderMode;
  switch (Config::Get(Config::GFX_SHADER_COMPILATION_MODE)) {
    case ShaderCompilationMode::Synchronous:
      shaderMode = @"Specialized (Default)";
      break;
    case ShaderCompilationMode::SynchronousUberShaders:
      shaderMode = @"Exclusive Ubershaders";
      break;
    case ShaderCompilationMode::AsynchronousUberShaders:
      shaderMode = @"Hybrid Ubershaders";
      break;
    case ShaderCompilationMode::AsynchronousSkipRendering:
      shaderMode = @"Skip Drawing";
      break;
    default:
      shaderMode = @"Error";
      break;
  }

  self.shaderModeCell.choiceSettingLabel.text = DOLCoreLocalizedString(shaderMode);

  // Auto IR value labels
  const int target_fps = Config::Get(Config::GFX_AUTO_IR_TARGET_FPS);
  self.autoIrTargetFpsCell.choiceSettingLabel.text = [NSString stringWithFormat:@"%d FPS", target_fps];

  const int min_scale = Config::Get(Config::GFX_AUTO_IR_MIN_SCALE);
  self.autoIrMinScaleCell.choiceSettingLabel.text = [NSString stringWithFormat:@"%dx", min_scale];

  const int max_scale = Config::Get(Config::GFX_AUTO_IR_MAX_SCALE);
  self.autoIrMaxScaleCell.choiceSettingLabel.text = [NSString stringWithFormat:@"%dx", max_scale];
}

// Use storyboard segues connected to the choice cells to navigate
- (BOOL)tableView:(UITableView*)tableView shouldHighlightRowAtIndexPath:(NSIndexPath*)indexPath {
  if (indexPath.section != 0) return [super tableView:tableView shouldHighlightRowAtIndexPath:indexPath];
  // Aspect ratio (row 1) and the three Auto IR choice rows (rows mapped by storyboard segues)
  return YES;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section != 0) return;
  // Use segues defined in storyboard from the respective cells
  if (tableView == self.tableView) {
    UITableViewCell* cell = [tableView cellForRowAtIndexPath:indexPath];
    if (cell == self.autoIrTargetFpsCell) {
      [self performSegueWithIdentifier:@"AIR-TGT-SEG2" sender:self];
    } else if (cell == self.autoIrMinScaleCell) {
      [self performSegueWithIdentifier:@"AIR-MIN-SEG2" sender:self];
    } else if (cell == self.autoIrMaxScaleCell) {
      [self performSegueWithIdentifier:@"AIR-MAX-SEG2" sender:self];
    }
  }
}

- (void)tableView:(UITableView*)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath*)indexPath {
  NSString* message = nil;

  switch (indexPath.section) {
    case 0:
      switch (indexPath.row) {
        case 0: {
          message = @"Selects which graphics API to use internally.<br><br>The software renderer is extremely "
                    "slow and only useful for debugging, so any of the other backends are "
                    "recommended. Different games and different GPUs will behave differently on each "
                    "backend, so for the best emulation experience it is recommended to try each and "
                    "select the backend that is least problematic.<br><br><dolphin_emphasis>If unsure, "
                    "select OpenGL.</dolphin_emphasis>";
          NSString* localizedMessage = DOLCoreLocalizedString(message);
          localizedMessage = [localizedMessage stringByReplacingOccurrencesOfString:@"OpenGL" withString:@"Vulkan"];
          [self showHelpWithMessage:localizedMessage];
          return;
        }
        case 1:
          message = @"Selects which aspect ratio to use when rendering.<br><br>Auto: Uses the native aspect "
                    "ratio<br>Force 16:9: Mimics an analog TV with a widescreen aspect ratio.<br>Force 4:3: "
                    "Mimics a standard 4:3 analog TV.<br><br><dolphin_emphasis>If unsure, select Auto.</dolphin_emphasis>";
          break;
        case 2:
          message = @"Waits for vertical blanks in order to prevent tearing.<br><br>Decreases performance "
                    "if emulation speed is below 100%.<br><br><dolphin_emphasis>If unsure, leave this unchecked.</dolphin_emphasis>";
          break;
        case 3:
          message = @"Shows an on-screen message whenever the Auto Internal Resolution controller changes the "
                    "internal resolution scale (e.g., 1x → 0.75x) along with current FPS.";
          break;
      }
      break;
    case 1:
      switch (indexPath.row) {
        case 0: return;
        case 1:
          message = @"Waits for all shaders to finish compiling before starting a game.";
          break;
      }
      break;
  }

  [self showHelpWithLocalizable:message];
}



@end
