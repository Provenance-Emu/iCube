# Nonblocking save orchestration host check

This compiles the actual repository `Common/Swift/TopBar/QuickSlot.swift` without changing its body. `Adapters.swift` replaces only unavailable app collaborators: bridge identity, toast recorder, localization passthrough, and an async save facade with an explicitly suspended continuation. The service adapter does not serialize or emulate state bytes.

`Main.swift` runs on MainActor and verifies: a first tap followed by a same-title session replacement before its Task executes performs no save; the accepted tap preserves game/session/slot; success waits for completion; a duplicate tap performs no additional serialization request; replacement-session completion produces no toast; failure produces the failure message.

From repository root:

```sh
swiftc -parse-as-library /tmp/icube-default-iso-audit/nonblocking-save/Adapters.swift Source/iOS/App/Common/Swift/TopBar/QuickSlot.swift /tmp/icube-default-iso-audit/nonblocking-save/Main.swift -o /tmp/icube-default-iso-audit/nonblocking-save/quick-slot-session-host
/tmp/icube-default-iso-audit/nonblocking-save/quick-slot-session-host
```

`session-result.log` contains the observed exit-0 result. This is actual UI orchestration coverage with controlled collaborators, not a core save, framework interoperability, SwiftUI lifetime, installed application or device run. Filmstrip/TV callbacks share the tested immutable request acceptance type; their actual SwiftUI disappearance/cancellation behavior remains an integration/UI check.
