// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVContinuity

/// The fallback machine is the one piece that must never be stubbed, so it gets
/// the heaviest coverage: every rung of the ladder, every local capability, and
/// the full error cross-product for the "nothing bootable" case.
final class FallbackMachineTests: XCTestCase {

    private typealias Machine = ContinuityFallbackMachine

    private func descriptor(
        _ kind: ContinuityFileKind, path: String = "x", required: Bool = true
    ) -> FileDescriptor {
        FileDescriptor(kind: kind, relativePath: path, sha256: "h", size: 1, required: required)
    }

    // MARK: - Rung 1: nothing bootable

    func testGameMissingAndNothingPulledFails() {
        let outcome = Machine.outcome(
            failedAt: .fetchingManifest,
            error: .serverUnreachable(detail: nil),
            local: .gameMissing,
            pulled: .nothing
        )
        XCTAssertEqual(outcome, .failed(.insufficientToBoot))
    }

    func testAPartialGameTransferCanNeverBoot() {
        // A state arrived but the disc image did not: there is nothing to load
        // the state INTO.
        let outcome = Machine.outcome(
            failedAt: .pulling,
            error: .serverUnreachable(detail: nil),
            local: .gameMissing,
            pulled: Machine.PulledArtifacts(
                saveStateUsable: true,
                requiredGameFilesComplete: false,
                missing: [descriptor(.gameFile)]
            )
        )
        XCTAssertEqual(outcome, .failed(.insufficientToBoot))
    }

    func testTransportErrorsAreRewrittenToInsufficientToBoot() {
        // "The connection dropped" describes the symptom; "not enough came
        // across to start the game" describes what the user is looking at.
        for error in [
            ContinuityError.serverUnreachable(detail: "timeout"),
            .cancelled,
            .checksumMismatch(relativePath: "x")
        ] {
            let outcome = Machine.outcome(
                failedAt: .pulling, error: error, local: .gameMissing, pulled: .nothing
            )
            XCTAssertEqual(outcome, .failed(.insufficientToBoot), "for \(error)")
        }
    }

    func testActionableErrorsSurviveUnchanged() {
        // These name a real cause the user (or a developer) can act on, so
        // flattening them into insufficientToBoot would destroy information.
        for error in [
            ContinuityError.tokenRejected,
            .manifestVersionUnsupported(found: 99),
            .gameNotFoundLocally,
            .noActiveSession,
            .invalidResponse(status: 500),
            .notPaired,
            .pairingDeclined
        ] {
            let outcome = Machine.outcome(
                failedAt: .fetchingManifest, error: error, local: .gameMissing, pulled: .nothing
            )
            XCTAssertEqual(outcome, .failed(error), "for \(error)")
        }
    }

    // MARK: - Rung 2: pulled state

    func testPulledStateWithAFullyPulledGameProceeds() {
        let outcome = Machine.outcome(
            failedAt: .verifying,
            error: .cancelled,
            local: .gameMissing,
            pulled: Machine.PulledArtifacts(saveStateUsable: true, requiredGameFilesComplete: true)
        )
        XCTAssertEqual(outcome, .proceedWithPulledState)
    }

    func testPulledStateWithALocalGameProceeds() {
        let outcome = Machine.outcome(
            failedAt: .pulling,
            error: .serverUnreachable(detail: nil),
            local: .gameAvailable(hasLocalSaveState: false),
            pulled: Machine.PulledArtifacts(saveStateUsable: true)
        )
        XCTAssertEqual(outcome, .proceedWithPulledState)
    }

    func testMissingNonEssentialsDowngradeToPartialAndAreReported() {
        let card = descriptor(.gameCubeMemoryCard, path: "GC/USA/MemoryCardA.raw")
        let outcome = Machine.outcome(
            failedAt: .pulling,
            error: .serverUnreachable(detail: nil),
            local: .gameAvailable(hasLocalSaveState: false),
            pulled: Machine.PulledArtifacts(saveStateUsable: true, missing: [card])
        )
        XCTAssertEqual(outcome, .proceedWithPulledStatePartial(missing: [card]))
    }

    func testAnUnverifiedStateDoesNotCountAsPulled() {
        // saveStateUsable is false when verification failed; we must fall
        // through rather than resume from a corrupt state.
        let outcome = Machine.outcome(
            failedAt: .verifying,
            error: .checksumMismatch(relativePath: "StateSaves/GALE01.s01"),
            local: .gameAvailable(hasLocalSaveState: true),
            pulled: Machine.PulledArtifacts(saveStateUsable: false)
        )
        XCTAssertEqual(outcome, .bootWithLatestLocalState)
    }

    // MARK: - Rungs 3 and 4: local fallbacks

    func testLocalGameWithLocalStateBootsFromTheLatestLocalState() {
        let outcome = Machine.outcome(
            failedAt: .minting,
            error: .invalidResponse(status: 500),
            local: .gameAvailable(hasLocalSaveState: true),
            pulled: .nothing
        )
        XCTAssertEqual(outcome, .bootWithLatestLocalState)
    }

    func testLocalGameWithNoStateAnywhereBootsFresh() {
        let outcome = Machine.outcome(
            failedAt: .minting,
            error: .invalidResponse(status: 500),
            local: .gameAvailable(hasLocalSaveState: false),
            pulled: .nothing
        )
        XCTAssertEqual(outcome, .bootFresh)
    }

    func testEvenAuthAndVersionFailuresDegradeToALocalBoot() {
        // "If the other device has the same game, just boot it" — showing a
        // protocol error the user cannot act on would be worse.
        for error in [ContinuityError.tokenRejected, .manifestVersionUnsupported(found: 99)] {
            let outcome = Machine.outcome(
                failedAt: .fetchingManifest,
                error: error,
                local: .gameAvailable(hasLocalSaveState: true),
                pulled: .nothing
            )
            XCTAssertEqual(outcome, .bootWithLatestLocalState, "for \(error)")
        }
    }

    // MARK: - Stage independence

    func testTheLadderDoesNotDependOnWhichStageFailed() {
        for stage in Machine.Stage.allCases {
            let outcome = Machine.outcome(
                failedAt: stage,
                error: .serverUnreachable(detail: nil),
                local: .gameAvailable(hasLocalSaveState: true),
                pulled: .nothing
            )
            XCTAssertEqual(outcome, .bootWithLatestLocalState, "stage \(stage)")
        }
    }

    // MARK: - Never a silent stub

    func testEveryInputCombinationProducesAnActionableOutcome() {
        // Exhaustive sweep: the machine must always answer with something the
        // app can either do or show. There is no "do nothing" case, and this
        // asserts none sneaks in.
        let locals: [Machine.LocalCapability] = [
            .gameAvailable(hasLocalSaveState: true),
            .gameAvailable(hasLocalSaveState: false),
            .gameMissing
        ]
        let pulls: [Machine.PulledArtifacts] = [
            .nothing,
            Machine.PulledArtifacts(saveStateUsable: true),
            Machine.PulledArtifacts(requiredGameFilesComplete: true),
            Machine.PulledArtifacts(saveStateUsable: true, requiredGameFilesComplete: true),
            Machine.PulledArtifacts(saveStateUsable: true, missing: [descriptor(.wiiSave)])
        ]
        let errors: [ContinuityError] = [
            .serverUnreachable(detail: nil), .tokenRejected, .cancelled,
            .checksumMismatch(relativePath: "x"), .noActiveSession, .insufficientToBoot
        ]

        var seen = Set<String>()
        for stage in Machine.Stage.allCases {
            for local in locals {
                for pulled in pulls {
                    for error in errors {
                        let outcome = Machine.outcome(
                            failedAt: stage, error: error, local: local, pulled: pulled
                        )
                        seen.insert(Self.label(outcome))
                        if case .failed(let reason) = outcome {
                            // A failure must always carry a reason a user can be shown.
                            XCTAssertNotNil(reason.errorDescription)
                        }
                    }
                }
            }
        }
        // Every rung is reachable from the sweep — otherwise one of them is
        // dead code that would never be exercised in the field either.
        XCTAssertEqual(
            seen,
            ["proceedWithPulledState", "proceedWithPulledStatePartial",
             "bootWithLatestLocalState", "bootFresh", "failed"]
        )
    }

    private static func label(_ outcome: ContinuityOutcome) -> String {
        switch outcome {
        case .proceedWithPulledState: return "proceedWithPulledState"
        case .proceedWithPulledStatePartial: return "proceedWithPulledStatePartial"
        case .bootWithLatestLocalState: return "bootWithLatestLocalState"
        case .bootFresh: return "bootFresh"
        case .failed: return "failed"
        }
    }
}

// MARK: - PullFailure → PulledArtifacts

final class PullFailureTranslationTests: XCTestCase {

    private func descriptor(_ kind: ContinuityFileKind, required: Bool = true) -> FileDescriptor {
        FileDescriptor(kind: kind, relativePath: "\(kind.rawValue)", sha256: "h", size: 1, required: required)
    }

    func testACompletedSaveStateIsReportedUsable() {
        let failure = PullFailure(
            underlying: .cancelled, completed: [descriptor(.saveState)], missing: [descriptor(.gameFile)]
        )
        XCTAssertTrue(failure.pulledArtifacts.saveStateUsable)
    }

    func testACompletedResumeStateAlsoCountsAsUsable() {
        let failure = PullFailure(
            underlying: .cancelled, completed: [descriptor(.resumeState)], missing: []
        )
        XCTAssertTrue(failure.pulledArtifacts.saveStateUsable)
    }

    func testAMissingGameFileMeansTheGameIsNotComplete() {
        let failure = PullFailure(
            underlying: .cancelled, completed: [descriptor(.saveState)], missing: [descriptor(.gameFile)]
        )
        XCTAssertFalse(failure.pulledArtifacts.requiredGameFilesComplete)
    }

    func testNothingMissingButNothingPulledIsNotCompleteEither() {
        // "No required file is missing" must not read as success when no game
        // file was attempted at all.
        let failure = PullFailure(underlying: .cancelled, completed: [], missing: [])
        XCTAssertFalse(failure.pulledArtifacts.requiredGameFilesComplete)
    }

    func testACompletedGameFileWithNothingRequiredMissingIsComplete() {
        let failure = PullFailure(
            underlying: .cancelled,
            completed: [descriptor(.gameFile)],
            missing: [descriptor(.saveStateThumbnail, required: false)]
        )
        XCTAssertTrue(failure.pulledArtifacts.requiredGameFilesComplete)
    }

    func testOptionalMissingFilesAreFilteredOutOfTheReportedMissingSet() {
        let failure = PullFailure(
            underlying: .cancelled,
            completed: [descriptor(.gameFile)],
            missing: [descriptor(.saveStateThumbnail, required: false), descriptor(.wiiSave)]
        )
        XCTAssertEqual(failure.pulledArtifacts.missing.map(\.kind), [.wiiSave])
    }
}
