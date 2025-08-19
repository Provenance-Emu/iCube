#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AchievementsSettingsViewController : UITableViewController

@property (weak, nonatomic) IBOutlet UISwitch* integrationSwitch;
@property (weak, nonatomic) IBOutlet UITextField* usernameField;
@property (weak, nonatomic) IBOutlet UITextField* passwordField;
@property (weak, nonatomic) IBOutlet UIButton* loginButton;
@property (weak, nonatomic) IBOutlet UIButton* logoutButton;
@property (weak, nonatomic) IBOutlet UISwitch* hardcoreSwitch;
@property (weak, nonatomic) IBOutlet UISwitch* unofficialSwitch;
@property (weak, nonatomic) IBOutlet UISwitch* encoreSwitch;
@property (weak, nonatomic) IBOutlet UISwitch* spectatorSwitch;
@property (weak, nonatomic) IBOutlet UISwitch* discordPresenceSwitch;
@property (weak, nonatomic) IBOutlet UISwitch* progressSwitch;

@end

NS_ASSUME_NONNULL_END
