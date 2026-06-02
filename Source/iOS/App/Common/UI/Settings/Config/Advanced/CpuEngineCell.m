// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "CpuEngineCell.h"

@implementation CpuEngineCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        if (!self.engineCell) {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            label.numberOfLines = 1;
            [self.contentView addSubview:label];
            [NSLayoutConstraint activateConstraints:@[
                [label.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16.0],
                [label.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16.0],
                [label.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]
            ]];
            _engineCell = label;
        }
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    // Initialization code
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];

    // Configure the view for the selected state
}

@end
