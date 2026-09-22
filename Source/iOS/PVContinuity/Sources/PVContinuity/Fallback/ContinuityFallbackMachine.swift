// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

/// What the receiving device should do once a pull ends — successfully or not.
///
/// Every case is an action the app can actually take. There is deliberately no
/// "silently do nothing" case: a handoff that cannot produce a running game
/// produces `.failed`, with the reason, which the UI must show.
public enum ContinuityOutcome: Sendable, Equatable {
    /// Everything required arrived (or was already local): boot and load the
    /// pulled state.
    case proceedWithPulledState
    /// The transfer died partway, but the pulled state plus a locally bootable
    /// game are enough. `missing` is what never arrived, so the app can say so.
    case proceedWithPulledStatePartial(missing: [FileDescriptor])
    /// No usable pulled state, but the game is local and has its own states:
    /// boot and load the most recent local one.
    case bootWithLatestLocalState
    /// Game is local, but no state survived anywhere: boot fresh.
    case bootFresh
    /// Nothing bootable on this device.
    case failed(ContinuityError)
}

/// Pure decision table for "the server died / the pull broke — what now?".
///
/// No I/O, no clock, no randomness: given the same four inputs it always
/// returns the same outcome, which is what makes it exhaustively testable and
/// why it is the one piece of this feature that must never be stubbed.
///
/// Lifted from iFly's `ContinuityFallbackMachine` with the semantics unchanged;
/// only the descriptor types differ.
public enum ContinuityFallbackMachine {

    /// Where in the flow the failure happened. Carried for telemetry and
    /// messaging; the ladder itself does not branch on it, because the right
    /// answer to "can this device run the game?" doesn't depend on which step
    /// was in progress when the answer became necessary.
    public enum Stage: Sendable, Equatable, CaseIterable {
        case fetchingManifest
        case minting
        case pulling
        case verifying
    }

    /// What the receiving device can do on its own, before anything was pulled.
    public enum LocalCapability: Sendable, Equatable {
        /// The game is present locally and bootable.
        case gameAvailable(hasLocalSaveState: Bool)
        case gameMissing
    }

    /// What made it across before the failure.
    public struct PulledArtifacts: Sendable, Equatable {
        /// A save state arrived **and passed checksum verification**. A state
        /// that failed verification counts as not pulled — resuming from a
        /// corrupt state is worse than booting fresh.
        public var saveStateUsable: Bool
        /// Every `required` game-file descriptor arrived and verified.
        public var requiredGameFilesComplete: Bool
        /// Required descriptors that never arrived or failed verification.
        public var missing: [FileDescriptor]

        public init(
            saveStateUsable: Bool = false,
            requiredGameFilesComplete: Bool = false,
            missing: [FileDescriptor] = []
        ) {
            self.saveStateUsable = saveStateUsable
            self.requiredGameFilesComplete = requiredGameFilesComplete
            self.missing = missing
        }

        public static let nothing = PulledArtifacts()
    }

    /// The ladder:
    ///
    ///   1. Is there a bootable game at all? Locally present, **or** fully
    ///      pulled. If not, stop — nothing below can help.
    ///   2. Did a usable state arrive? → resume from it (flagging anything
    ///      still missing, so the user is told rather than surprised).
    ///   3. Does the local game have its own states? → resume from the latest.
    ///   4. Otherwise → boot fresh.
    ///
    /// The ladder applies to **every** error kind, including auth and version
    /// failures: if the other device turned out to have the same game we
    /// already own, the useful thing to do is boot it, not to show an error
    /// about a protocol mismatch the user cannot act on.
    ///
    /// The one place the error kind matters is step 1's failure: when nothing
    /// is bootable, a transport-shaped error (`serverUnreachable`, `cancelled`,
    /// `checksumMismatch`) is replaced by `insufficientToBoot`, because "the
    /// connection dropped" describes the symptom while "not enough came across
    /// to start the game" describes what the user is actually looking at.
    /// Errors that name a real, actionable cause (version mismatch, rejected
    /// token, game not found) are surfaced unchanged.
    public static func outcome(
        failedAt stage: Stage,
        error: ContinuityError,
        local: LocalCapability,
        pulled: PulledArtifacts
    ) -> ContinuityOutcome {
        let gameBootable: Bool
        let hasLocalState: Bool
        switch local {
        case .gameAvailable(let hasState):
            gameBootable = true
            hasLocalState = hasState
        case .gameMissing:
            gameBootable = pulled.requiredGameFilesComplete
            hasLocalState = false
        }

        guard gameBootable else {
            switch error {
            case .serverUnreachable, .cancelled, .checksumMismatch:
                return .failed(.insufficientToBoot)
            default:
                return .failed(error)
            }
        }

        if pulled.saveStateUsable {
            return pulled.missing.isEmpty
                ? .proceedWithPulledState
                : .proceedWithPulledStatePartial(missing: pulled.missing)
        }

        return hasLocalState ? .bootWithLatestLocalState : .bootFresh
    }
}
