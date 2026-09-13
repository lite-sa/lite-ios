#if canImport(UIKit)
import SwiftUI

/// Save-card toggle — matches web checkout `Switch` (44×24).
/// Inactive thumb uses a tight soft drop shadow (no track shadow) so it doesn’t muddy on white.
public struct LiteSwitch: View {
    @Binding var isOn: Bool
    var enabled: Bool = true

    public init(isOn: Binding<Bool>, enabled: Bool = true) {
        self._isOn = isOn
        self.enabled = enabled
    }

    public var body: some View {
        let trackColor = isOn ? LiteTheme.Colors.primary : LiteTheme.Colors.input
        let thumbOffset: CGFloat = isOn ? 18 : 0

        Button {
            guard enabled else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 100, style: .continuous)
                    .fill(trackColor)
                    .frame(width: 44, height: 22)

                Circle()
                    .fill(Color.white)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Circle().stroke(isOn ? LiteTheme.Colors.primary : Color.clear, lineWidth: 2)
                    )
                    .compositingGroup()
                    .shadow(
                        color: Color.black.opacity(isOn ? 0.12 : 0.14),
                        radius: 1.5,
                        x: 0,
                        y: 1
                    )
                    .offset(x: thumbOffset)
            }
            .frame(width: 44, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
#endif
