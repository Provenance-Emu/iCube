#import "Fixture.h"
#import <UIKit/UIKit.h>
#import <CoreNFC/CoreNFC.h>
#import <stdatomic.h>

static int fixtureMode;
static atomic_int reads;
static dispatch_semaphore_t releaseProbe;

void FixtureConfigure(int mode) {
    fixtureMode = mode;
    releaseProbe = dispatch_semaphore_create(0);
}
int FixtureReadCount(void) { return atomic_load(&reads); }
void FixtureRelease(void) { dispatch_semaphore_signal(releaseProbe); }

@implementation UIDevice
+ (UIDevice *)currentDevice { return [UIDevice new]; }
- (UIUserInterfaceIdiom)userInterfaceIdiom {
    return fixtureMode == 3 ? UIUserInterfaceIdiomPad : UIUserInterfaceIdiomPhone;
}
@end

@implementation NFCNDEFReaderSession
+ (BOOL)readingAvailable {
    atomic_fetch_add(&reads, 1);
    if (fixtureMode == 0) {
        [NSException raise:NSInvalidArgumentException
                    format:@"Synthetic NFC capability probe failure"];
    }
    if (fixtureMode == 4) {
        dispatch_semaphore_wait(releaseProbe, DISPATCH_TIME_FOREVER);
    }
    return fixtureMode != 2;
}
@end
