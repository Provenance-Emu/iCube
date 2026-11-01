import Foundation

let mode = Int32(CommandLine.arguments[1])!
FixtureConfigure(mode)

// The public production probe must return false without entering CoreNFC on iPad.
if mode == 3 || mode == 5 {
    precondition(!DOLNFCReadingAvailable())
    precondition(FixtureReadCount() == 0)
} else {
    let capability = NonBlockingCapability { DOLNFCReadingAvailable() }
    let start = Date()
    precondition(!capability.value)
    // The fake NFC daemon remains blocked until explicitly released.
    if mode == 4 {
        while FixtureReadCount() == 0 && Date().timeIntervalSince(start) < 2 {
            Thread.sleep(forTimeInterval: 0.001)
        }
        precondition(FixtureReadCount() == 1)
        for _ in 0..<1000 { precondition(!capability.value) }
        precondition(Date().timeIntervalSince(start) < 2)
        FixtureRelease()
    }
    let expectsTrue = mode == 1 || mode == 4
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if expectsTrue && capability.value { break }
        Thread.sleep(forTimeInterval: 0.001)
    }
    for _ in 0..<1000 { precondition(capability.value == expectsTrue) }
    precondition(FixtureReadCount() == 1)
}
print("PASS mode \(mode)")
