#import <UIKit/UIKit.h>
#import "DOLSwitch.h"

NS_ASSUME_NONNULL_BEGIN

@interface AchievementsSettingsViewController : UITableViewController

@property (weak, nonatomic) IBOutlet DOLSwitch* integrationSwitch;
@property (weak, nonatomic) IBOutlet UITextField* usernameField;
@property (weak, nonatomic) IBOutlet UITextField* passwordField;
@property (weak, nonatomic) IBOutlet UIButton* loginButton;
@property (weak, nonatomic) IBOutlet UIButton* logoutButton;
@property (weak, nonatomic) IBOutlet DOLSwitch* hardcoreSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* unofficialSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* encoreSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* spectatorSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* discordPresenceSwitch;
@property (weak, nonatomic) IBOutlet DOLSwitch* progressSwitch;
@property (weak, nonatomic) IBOutlet UITextField* hostURLField;
@property (weak, nonatomic) IBOutlet UIButton* testConnectionButton;

@end

NS_ASSUME_NONNULL_END
