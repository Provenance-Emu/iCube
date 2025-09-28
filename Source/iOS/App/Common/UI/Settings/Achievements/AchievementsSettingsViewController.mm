#import "AchievementsSettingsViewController.h"

#ifdef USE_RETRO_ACHIEVEMENTS
#import "Core/Config/AchievementSettings.h"
#import "Core/AchievementManager.h"
#endif
#import "Core/Core.h"
#import "Core/System.h"
#import "Common/Config/Config.h"

@interface AchievementsSettingsViewController () {
  BOOL _usesDynamicUI;
#ifdef USE_RETRO_ACHIEVEMENTS
  UIActivityIndicatorView* _loginSpinner;
  NSTimer* _loginTimer;
  NSString* _cachedPassword;
  NSString* _hostOverride;
#endif
}
@end

@implementation AchievementsSettingsViewController

- (void)viewDidLoad {
  [super viewDidLoad];
#ifdef USE_RETRO_ACHIEVEMENTS
  self.title = @"Achievements";

  _usesDynamicUI = (self.integrationSwitch == nil);
  if (_usesDynamicUI) {
    UITableView* tv = nil;
    if (@available(iOS 13.0, *)) {
#if !TARGET_OS_TV
      tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
#else
      tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
#endif
    } else {
      tv = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    }
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView = tv;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
  }

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_onRAFailedLogin:) name:@"DOLRAFailedLogin" object:nil];

  if (!_usesDynamicUI) {
    self.integrationSwitch.on = Config::Get(Config::RA_ENABLED);
    [self.integrationSwitch addTarget:self action:@selector(integrationChanged) forControlEvents:UIControlEventValueChanged];

    std::string username = Config::Get(Config::RA_USERNAME);
    if (!username.empty()) {
      self.usernameField.text = [NSString stringWithUTF8String:username.c_str()];
    }
    const bool hasToken = AchievementManager::GetInstance().HasAPIToken();
    self.usernameField.enabled = self.integrationSwitch.on && !hasToken;

    self.passwordField.secureTextEntry = YES;
    self.passwordField.enabled = self.integrationSwitch.on && !hasToken;
    // Restore cached password for convenience during repeated login attempts
    if (!hasToken) {
      NSString* cached = [NSUserDefaults.standardUserDefaults stringForKey:@"dol_ra_cached_password"] ?: @"";
      self.passwordField.text = cached;
    }

    if (self.hostURLField) {
      std::string host = Config::Get(Config::RA_HOST_URL);
      if (!host.empty()) self.hostURLField.text = [NSString stringWithUTF8String:host.c_str()];
      [self.hostURLField addTarget:self action:@selector(hostChanged:) forControlEvents:UIControlEventEditingChanged];
    }
    if (self.testConnectionButton) {
      [self.testConnectionButton addTarget:self action:@selector(testConnectionPressed) forControlEvents:UIControlEventTouchUpInside];
    }

    [self.loginButton addTarget:self action:@selector(loginPressed) forControlEvents:UIControlEventTouchUpInside];
    [self.logoutButton addTarget:self action:@selector(logoutPressed) forControlEvents:UIControlEventTouchUpInside];

    self.loginButton.hidden = hasToken;
    self.logoutButton.hidden = !hasToken;
    self.loginButton.enabled = self.integrationSwitch.on;
  }
#endif
}

#ifdef USE_RETRO_ACHIEVEMENTS
- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:@"DOLRAFailedLogin" object:nil];
}

- (void)_onRAFailedLogin:(NSNotification*)note {
  __weak AchievementsSettingsViewController* weakself = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong AchievementsSettingsViewController* strongself = weakself;
    if (!strongself) return;
    [strongself _stopLoginSpinner];
    [strongself->_loginTimer invalidate];
    strongself->_loginTimer = nil;
    NSNumber* codeNum = note.userInfo[@"code"];
    NSInteger code = codeNum != nil ? codeNum.integerValue : -1;
    NSString* message = @"Could not authenticate with RetroAchievements.";
    switch (code) {
      case RC_INVALID_CREDENTIALS:
        message = @"Invalid username or password.";
        break;
      case RC_NO_RESPONSE:
        message = @"No response from server. Check your connection.";
        break;
      default:
        break;
    }
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Login Failed" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [strongself presentViewController:alert animated:YES completion:nil];
    if (strongself->_usesDynamicUI) {
      NSIndexPath* passPath = [NSIndexPath indexPathForRow:2 inSection:0];
      UITableViewCell* passCell = [strongself.tableView cellForRowAtIndexPath:passPath];
      if ([passCell.accessoryView isKindOfClass:[UITextField class]]) {
        ((UITextField*)passCell.accessoryView).text = strongself->_cachedPassword ?: @"";
      }
    } else {
      strongself.passwordField.text = strongself->_cachedPassword ?: @"";
    }
    strongself->_cachedPassword = nil;
  });
}

- (void)integrationChanged {
  Config::SetBaseOrCurrent(Config::RA_ENABLED, self.integrationSwitch.on);
  if (self.integrationSwitch.on) {
    AchievementManager::GetInstance().Init(nullptr);
  } else {
    AchievementManager::GetInstance().Shutdown();
  }
}

- (NSString*)_normalizedHostURL:(NSString*)text {
  if (!text) return @"";
  NSString* trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSString* lower = [trimmed lowercaseString];
  if (lower.length == 0) return @"";
  if ([lower containsString:@"retroachievments.org"]) {
    lower = [lower stringByReplacingOccurrencesOfString:@"retroachievments.org" withString:@"retroachievements.org"];
    fprintf(stderr, "[RA] Normalized host typo to retroachievements.org\n");
  }
  if (![lower hasPrefix:@"http://"] && ![lower hasPrefix:@"https://"]) {
    lower = [@"https://" stringByAppendingString:lower];
  }
  return lower;
}

- (void)hostChanged:(UITextField*)sender {
  _hostOverride = [sender.text copy];
}

- (void)_applyHostOverrideIfNeededAndReinit {
  std::string current = Config::Get(Config::RA_HOST_URL);
  NSString* desired = _hostOverride ?: @"";
  NSString* normalized = [self _normalizedHostURL:desired];
  std::string newHost = normalized.length ? normalized.UTF8String : "";
  if (newHost != current) {
    Config::SetBaseOrCurrent(Config::RA_HOST_URL, newHost);
    AchievementManager::GetInstance().Shutdown();
    AchievementManager::GetInstance().Init(nullptr);
  }
}

- (void)testConnectionPressed {
  [self _applyHostOverrideIfNeededAndReinit];
  std::string host = Config::Get(Config::RA_HOST_URL);
  NSString* base = host.empty() ? @"https://retroachievements.org" : [NSString stringWithUTF8String:host.c_str()];
  NSURL* url = [NSURL URLWithString:base];
  if (!url) {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Invalid URL" message:@"Please enter a valid server URL." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }
  NSURLSessionConfiguration* cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  cfg.timeoutIntervalForRequest = 10;
  NSURLSession* session = [NSURLSession sessionWithConfiguration:cfg];
  __weak AchievementsSettingsViewController* weakself = self;
  NSURLSessionDataTask* task = [session dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    __strong AchievementsSettingsViewController* strongself = weakself;
    NSString* msg = nil;
    if (error) {
      msg = [NSString stringWithFormat:@"Failed: %@", error.localizedDescription];
      fprintf(stderr, "[RA] Connectivity probe failed: %s\n", error.localizedDescription.UTF8String);
    } else {
      NSInteger status = [(NSHTTPURLResponse*)response statusCode];
      msg = [NSString stringWithFormat:@"HTTP %ld", (long)status];
      fprintf(stderr, "[RA] Connectivity probe success: HTTP %ld\n", (long)status);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Test Connection" message:msg preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
      [strongself presentViewController:alert animated:YES completion:nil];
    });
  }];
  [task resume];
}

- (void)_startLoginSpinner {
  __weak AchievementsSettingsViewController* weakself = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong AchievementsSettingsViewController* strongself = weakself;
    if (!strongself->_loginSpinner) {
      strongself->_loginSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    }
    [strongself->_loginSpinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:strongself->_loginSpinner];
  });
}

- (void)_stopLoginSpinner {
  __weak AchievementsSettingsViewController* weakself = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong AchievementsSettingsViewController* strongself = weakself;
    [strongself->_loginSpinner stopAnimating];
    self.navigationItem.rightBarButtonItem = nil;
  });
}

- (void)_pollLoginStatus {
  if (AchievementManager::GetInstance().HasAPIToken()) {
    __weak AchievementsSettingsViewController* weakself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong AchievementsSettingsViewController* strongself = weakself;
      if (!strongself) return;
      [strongself->_loginTimer invalidate];
      strongself->_loginTimer = nil;
      strongself->_cachedPassword = nil;
      [strongself _stopLoginSpinner];
      [strongself.tableView reloadData];
      if (!strongself->_usesDynamicUI) {
        strongself.loginButton.hidden = YES;
        strongself.logoutButton.hidden = NO;
        strongself.usernameField.enabled = NO;
        strongself.passwordField.enabled = NO;
      }
    });
  }
}

- (void)_completeLoginWithTimeout {
  __weak AchievementsSettingsViewController* weakself = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong AchievementsSettingsViewController* strongself = weakself;
    if (!strongself) return;
    [strongself->_loginTimer invalidate];
    strongself->_loginTimer = nil;
    [strongself _stopLoginSpinner];
    if (!AchievementManager::GetInstance().HasAPIToken()) {
      UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Login Failed" message:@"Could not authenticate with RetroAchievements. Check your credentials or network." preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
      [strongself presentViewController:alert animated:YES completion:nil];
      if (strongself->_usesDynamicUI) {
        NSIndexPath* passPath = [NSIndexPath indexPathForRow:2 inSection:0];
        UITableViewCell* passCell = [strongself.tableView cellForRowAtIndexPath:passPath];
        if ([passCell.accessoryView isKindOfClass:[UITextField class]]) {
          ((UITextField*)passCell.accessoryView).text = strongself->_cachedPassword ?: @"";
        }
      } else {
        strongself.passwordField.text = strongself->_cachedPassword ?: @"";
      }
    }
    strongself->_cachedPassword = nil;
  });
}

- (void)loginPressed {
  Config::SetBaseOrCurrent(Config::RA_USERNAME, self.usernameField.text.UTF8String ? self.usernameField.text.UTF8String : "");
  if (!Config::Get(Config::RA_ENABLED)) return;
  NSString* pw = nil;
  if (_usesDynamicUI) {
    UITableViewCell* passCell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];
    if ([passCell.accessoryView isKindOfClass:[UITextField class]]) {
      pw = ((UITextField*)passCell.accessoryView).text ?: @"";
    } else {
      pw = @"";
    }
  } else {
    pw = self.passwordField.text ?: @"";
  }
  _cachedPassword = [pw copy];
  // Cache for convenience across attempts (non-secure; for testing)
  if (_cachedPassword.length > 0) {
    [NSUserDefaults.standardUserDefaults setObject:_cachedPassword forKey:@"dol_ra_cached_password"];
  }

  [self _applyHostOverrideIfNeededAndReinit];
  [self _startLoginSpinner];
  AchievementManager::GetInstance().Init(nullptr);
  if (!AchievementManager::GetInstance().HasAPIToken()) {
    AchievementManager::GetInstance().Login(pw.UTF8String ? pw.UTF8String : "");
  }
  [_loginTimer invalidate];
  _loginTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(_pollLoginStatus) userInfo:nil repeats:YES];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self _completeLoginWithTimeout];
  });
}

- (void)logoutPressed {
  AchievementManager::GetInstance().Logout();
  [NSUserDefaults.standardUserDefaults removeObjectForKey:@"dol_ra_cached_password"];
  [self.tableView reloadData];
}

- (void)hardcoreChanged {
  Config::SetBaseOrCurrent(Config::RA_HARDCORE_ENABLED, self.hardcoreSwitch.on);
}

- (void)unofficialChanged {
  Config::SetBaseOrCurrent(Config::RA_UNOFFICIAL_ENABLED, self.unofficialSwitch.on);
}

- (void)encoreChanged {
  Config::SetBaseOrCurrent(Config::RA_ENCORE_ENABLED, self.encoreSwitch.on);
}

- (void)spectatorChanged {
  Config::SetBaseOrCurrent(Config::RA_SPECTATOR_ENABLED, self.spectatorSwitch.on);
  AchievementManager::GetInstance().SetSpectatorMode();
}

- (void)discordChanged {
  Config::SetBaseOrCurrent(Config::RA_DISCORD_PRESENCE_ENABLED, self.discordPresenceSwitch.on);
}

- (void)progressChanged {
  Config::SetBaseOrCurrent(Config::RA_PROGRESS_ENABLED, self.progressSwitch.on);
}

// Dynamic UI fallback
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return _usesDynamicUI ? 3 : [super numberOfSectionsInTableView:tableView];
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  if (!_usesDynamicUI) return [super tableView:tableView titleForHeaderInSection:section];
  if (section == 0) return @"RetroAchievements";
  if (section == 1) return @"Options";
  return @"Advanced";
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  if (!_usesDynamicUI) return [super tableView:tableView numberOfRowsInSection:section];
  if (section == 0) {
    // Enable, Username, Password, Login/Logout
    return 4;
  }
  if (section == 1) {
    // Hardcore, Unofficial, Encore, Spectator, Discord, Progress
    return 6;
  }
  // Advanced: Host URL, Test Connection
  return 2;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  if (!_usesDynamicUI) return [super tableView:tableView cellForRowAtIndexPath:indexPath];

  NSString* reuse = @"ACHCell";
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:reuse];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
  }
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  cell.accessoryView = nil;
  cell.textLabel.text = @"";
  cell.detailTextLabel.text = @"";

  if (indexPath.section == 0) {
    const bool enabled = Config::Get(Config::RA_ENABLED);
    const bool hasToken = AchievementManager::GetInstance().HasAPIToken();
    switch (indexPath.row) {
      case 0: {
        cell.textLabel.text = @"Enable Integration";
        DOLSwitch* sw = [[DOLSwitch alloc] init];
        sw.on = enabled;
        [sw addTarget:self action:@selector(dynamicToggleChanged:) forControlEvents:UIControlEventValueChanged];
        sw.tag = 100; // RA_ENABLED
        cell.accessoryView = sw;
        break;
      }
      case 1: {
        cell.textLabel.text = @"Username";
        UITextField* tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 180, 30)];
        tf.placeholder = @"Username";
        std::string u = Config::Get(Config::RA_USERNAME);
        if (!u.empty()) tf.text = [NSString stringWithUTF8String:u.c_str()];
        tf.textAlignment = NSTextAlignmentRight;
        tf.enabled = enabled && !hasToken;
        tf.tag = 200; // username
        [tf addTarget:self action:@selector(dynamicTextChanged:) forControlEvents:UIControlEventEditingChanged];
        cell.accessoryView = tf;
        break;
      }
      case 2: {
        cell.textLabel.text = @"Password";
        UITextField* tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 180, 30)];
        tf.placeholder = @"Password";
        tf.secureTextEntry = YES;
        tf.textAlignment = NSTextAlignmentRight;
        tf.enabled = enabled && !hasToken;
        tf.tag = 201; // password
        [tf addTarget:self action:@selector(dynamicTextChanged:) forControlEvents:UIControlEventEditingChanged];
        if (_cachedPassword.length > 0) tf.text = _cachedPassword;
        cell.accessoryView = tf;
        break;
      }
      case 3: {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.text = hasToken ? @"Log Out" : @"Log In";
        break;
      }
    }
  } else if (indexPath.section == 1) {
    DOLSwitch* sw = [[DOLSwitch alloc] init];
    [sw addTarget:self action:@selector(dynamicToggleChanged:) forControlEvents:UIControlEventValueChanged];
    switch (indexPath.row) {
      case 0: cell.textLabel.text = @"Hardcore Mode"; sw.on = Config::Get(Config::RA_HARDCORE_ENABLED); sw.tag = 300; break;
      case 1: cell.textLabel.text = @"Enable Unofficial"; sw.on = Config::Get(Config::RA_UNOFFICIAL_ENABLED); sw.tag = 301; break;
      case 2: cell.textLabel.text = @"Encore Mode"; sw.on = Config::Get(Config::RA_ENCORE_ENABLED); sw.tag = 302; break;
      case 3: cell.textLabel.text = @"Spectator Mode"; sw.on = Config::Get(Config::RA_SPECTATOR_ENABLED); sw.tag = 303; break;
      case 4: cell.textLabel.text = @"Discord Presence"; sw.on = Config::Get(Config::RA_DISCORD_PRESENCE_ENABLED); sw.tag = 304; break;
      case 5: cell.textLabel.text = @"Show Progress Popups"; sw.on = Config::Get(Config::RA_PROGRESS_ENABLED); sw.tag = 305; break;
    }
    cell.accessoryView = sw;
  } else {
    switch (indexPath.row) {
      case 0: {
        cell.textLabel.text = @"Server URL";
        UITextField* tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
        tf.placeholder = @"https://retroachievements.org";
        std::string host = Config::Get(Config::RA_HOST_URL);
        if (!host.empty()) tf.text = [NSString stringWithUTF8String:host.c_str()];
        tf.textAlignment = NSTextAlignmentRight;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.keyboardType = UIKeyboardTypeURL;
        tf.tag = 400; // host url
        [tf addTarget:self action:@selector(dynamicTextChanged:) forControlEvents:UIControlEventEditingChanged];
        cell.accessoryView = tf;
        break;
      }
      case 1: {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.text = @"Test Connection";
        break;
      }
    }
  }
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  if (!_usesDynamicUI) return;
  if (indexPath.section == 0 && indexPath.row == 3) {
    const bool hasToken = AchievementManager::GetInstance().HasAPIToken();
    if (!hasToken) {
      NSString* username = @"";
      NSString* password = @"";
      UITableViewCell* userCell = [tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
      UIView* userAV = userCell.accessoryView;
      UITextField* userTF = [userAV isKindOfClass:[UITextField class]] ? (UITextField*)userAV : nil;
      UITableViewCell* passCell = [tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];
      UIView* passAV = passCell.accessoryView;
      UITextField* passTF = [passAV isKindOfClass:[UITextField class]] ? (UITextField*)passAV : nil;
      if (userTF) username = userTF.text ?: @"";
      if (passTF) password = passTF.text ?: @"";
      Config::SetBaseOrCurrent(Config::RA_USERNAME, username.UTF8String ? username.UTF8String : "");
      _cachedPassword = [password copy];
      [self _applyHostOverrideIfNeededAndReinit];
      [self _startLoginSpinner];
      AchievementManager::GetInstance().Init(nullptr);
      AchievementManager::GetInstance().Login(password.UTF8String ? password.UTF8String : "");
      [_loginTimer invalidate];
      _loginTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(_pollLoginStatus) userInfo:nil repeats:YES];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _completeLoginWithTimeout];
      });
    } else {
      AchievementManager::GetInstance().Logout();
      dispatch_async(dispatch_get_main_queue(), ^{ [tableView reloadData]; });
    }
  } else if (indexPath.section == 2 && indexPath.row == 1) {
    [self testConnectionPressed];
  }
}

- (void)dynamicToggleChanged:(DOLSwitch*)sender {
  switch (sender.tag) {
    case 100: Config::SetBaseOrCurrent(Config::RA_ENABLED, sender.on); [self.tableView reloadData]; break;
    case 300: Config::SetBaseOrCurrent(Config::RA_HARDCORE_ENABLED, sender.on); break;
    case 301: Config::SetBaseOrCurrent(Config::RA_UNOFFICIAL_ENABLED, sender.on); break;
    case 302: Config::SetBaseOrCurrent(Config::RA_ENCORE_ENABLED, sender.on); break;
    case 303: Config::SetBaseOrCurrent(Config::RA_SPECTATOR_ENABLED, sender.on); AchievementManager::GetInstance().SetSpectatorMode(); break;
    case 304: Config::SetBaseOrCurrent(Config::RA_DISCORD_PRESENCE_ENABLED, sender.on); break;
    case 305: Config::SetBaseOrCurrent(Config::RA_PROGRESS_ENABLED, sender.on); break;
  }
}

- (void)dynamicTextChanged:(UITextField*)sender {
  if (sender.tag == 200) {
    Config::SetBaseOrCurrent(Config::RA_USERNAME, sender.text.UTF8String ? sender.text.UTF8String : "");
  } else if (sender.tag == 201) {
    // store temporarily so reloads keep the typed password during login attempts
    _cachedPassword = [sender.text copy];
    if (_cachedPassword.length > 0) {
      [NSUserDefaults.standardUserDefaults setObject:_cachedPassword forKey:@"dol_ra_cached_password"];
    }
  } else if (sender.tag == 400) {
    _hostOverride = [sender.text copy];
  }
}
#endif

@end
