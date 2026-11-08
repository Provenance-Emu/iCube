// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The 6-digit pairing code another device shows, typed on this one.
///
/// One definition for every pairing surface (library browse, handoff), so the
/// keypad, the digit filter and the auto-submit cannot drift apart again: one
/// copy used to accept letters and both brought up a full keyboard.
///
/// - The keypad is the number pad. On iOS the field takes focus on appear, so
///   the keypad is up without a tap. tvOS has no auto-raised keyboard and its
///   focus is the library's to route (a second binding on the field would
///   fight the one the column hands in), so there the caller decides.
/// - Anything but digits is dropped and the code is capped at six (a pasted
///   "123 456" or a one-time-code suggestion still lands as `123456`).
/// - The sixth digit submits. The number pad has no return key, so the Pair
///   button stays as its own row too; on tvOS a row holding a field and a
///   button is one focus target and the button would be unreachable.
struct ContinuityPairingCodeField: View {
    @Binding var code: String
    let onSubmit: (String) -> Void

    static let length = 6

    #if !os(tvOS)
    @FocusState private var focused: Bool
    #endif
    /// The code last sent, so a re-render at six digits does not submit twice.
    @State private var submitted: String?

    var body: some View {
        TextField(L("000000"), text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .autocorrectionDisabled()
            .font(.title2.monospacedDigit())
            .multilineTextAlignment(.center)
            #if !os(tvOS)
            .focused($focused)
            #endif
            .accessibilityLabel(L("Pairing code"))
            .onChange(of: code) { _, newValue in
                let digits = Self.sanitized(newValue)
                if digits != newValue {
                    code = digits
                    return
                }
                guard Self.isComplete(digits) else {
                    submitted = nil
                    return
                }
                guard submitted != digits else { return }
                submitted = digits
                #if !os(tvOS)
                focused = false
                #endif
                onSubmit(digits)
            }
            .onAppear {
                submitted = nil
                #if !os(tvOS)
                focused = true
                #endif
            }
    }

    /// Digits only, at most `length` of them.
    static func sanitized(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(length))
    }

    static func isComplete(_ code: String) -> Bool {
        code.count == length && code.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
