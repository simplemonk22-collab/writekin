import SwiftUI

/// The small, one-line (may wrap) explainer caption shown atop a screen —
/// e.g. Browse's "Everything Writekin read from your sources…". Shared
/// style across every screen that has one.
///
/// Deliberately NO `.fixedSize(horizontal: false, vertical: true)`: a
/// wrapping text whose height depends on width, sharing a container with an
/// AppKit-backed `Table`/`List`, sent macOS 26 into a layout recursion
/// ("reentrant operation in its NSTableView delegate") that corrupted the
/// window's sidebar table into an empty, unrecoverable state. The
/// leading-aligned max-width frame gives wrapped captions a stable, single
/// measured width instead, which both avoids the recursion and keeps line
/// heights consistent across layout contexts.
struct ScreenCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
