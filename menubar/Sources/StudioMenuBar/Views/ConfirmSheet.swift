// ConfirmSheet.swift -- reusable confirmation dialog wrapper.
//
// This file exists for completeness per the plan. Each tab currently uses
// `.confirmationDialog` inline for tight binding to its selection state, so
// this wrapper is intentionally minimal but available for future reuse.

import SwiftUI

struct ConfirmSheet<T>: ViewModifier {
    let title: String
    @Binding var target: T?
    let messageBuilder: (T) -> String
    let destructiveLabel: String
    let onConfirm: (T) async -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(
                get: { target != nil },
                set: { if !$0 { target = nil } }
            ),
            presenting: target
        ) { t in
            Button(destructiveLabel, role: .destructive) {
                Task { await onConfirm(t) }
            }
            Button("Cancel", role: .cancel) { target = nil }
        } message: { t in
            Text(messageBuilder(t))
        }
    }
}
