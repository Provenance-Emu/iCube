#import "GraphicsAutoIrTargetFpsViewController.h"

#import "Core/Config/GraphicsSettings.h"

@implementation GraphicsAutoIrTargetFpsViewController {
  UISlider* _slider;
  UILabel* _valueLabel;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Target FPS";
  self.tableView = [[UITableView alloc] initWithFrame:self.tableView.frame style:UITableViewStyleInsetGrouped];
  self.tableView.allowsSelection = NO;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView { return 1; }
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return 1; }

- (CGFloat)tableView:(UITableView*)tableView heightForRowAtIndexPath:(NSIndexPath*)indexPath { return 84.0; }

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  static NSString* cellId = @"AutoIrFpsSliderCell";
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:cellId];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    UILabel* title = cell.textLabel;
    title.text = @"Target FPS";
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];

    _valueLabel = cell.detailTextLabel;
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];

    _slider = [[UISlider alloc] initWithFrame:CGRectZero];
    _slider.minimumValue = 30;
    _slider.maximumValue = 60;
    _slider.continuous = YES;
    [_slider addTarget:self action:@selector(valueChanged:) forControlEvents:UIControlEventValueChanged];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:_slider];

    [NSLayoutConstraint activateConstraints:@[
      [_slider.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
      [_slider.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
      [_slider.bottomAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.bottomAnchor]
    ]];
  }

  const int current = Config::Get(Config::GFX_AUTO_IR_TARGET_FPS);
  _slider.value = current;
  _valueLabel.text = [NSString stringWithFormat:@"%d FPS", current];

  return cell;
}

- (void)valueChanged:(UISlider*)slider {
  int value = (int)roundf(slider.value);
  slider.value = value;
  _valueLabel.text = [NSString stringWithFormat:@"%d FPS", value];
  Config::SetBaseOrCurrent(Config::GFX_AUTO_IR_TARGET_FPS, value);
}

@end
