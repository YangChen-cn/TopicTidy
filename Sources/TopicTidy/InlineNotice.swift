import SwiftUI

/// The card used to ask the user something, or to report a failure, inside the
/// window content.
///
/// Sheets are not an option on the menu bar panel: hosting one makes the panel
/// resign key, so it closes under the pointer and the click never lands — the
/// recovery confirmation used to need a second click that way. Anything that
/// needs an answer renders here instead, next to the control that asked.
struct InlineNotice<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    var tint: AnyShapeStyle = AnyShapeStyle(.orange)
    var compact = false
    var maxWidth: CGFloat = .infinity
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            Label(title, systemImage: systemImage)
                .font(compact ? .callout.weight(.semibold) : .headline)
                .foregroundStyle(tint)
            Text(message)
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) { actions }
                .padding(.top, compact ? 1 : 3)
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        .padding(compact ? 12 : 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
