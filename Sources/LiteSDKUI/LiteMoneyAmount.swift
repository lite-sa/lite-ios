#if canImport(UIKit)
import SwiftUI

/// Formats a minor-unit amount for display (numeric portion only).
public func formatLiteMajorAmount(amountMinor: Int) -> String {
    String(format: "%.2f", Double(amountMinor) / 100.0)
}

/// Pay-button / totals amount — mirrors web MoneyDisplayValue / Android `LiteMoneyAmount`.
public struct LiteMoneyAmount: View {
    let amountMinor: Int
    let currency: String
    var font: Font = LiteTheme.Typography.bodySemiBold()
    var color: Color = LiteTheme.Colors.textPrimary
    var symbolSize: CGFloat = 18

    public init(
        amountMinor: Int,
        currency: String,
        font: Font = LiteTheme.Typography.bodySemiBold(),
        color: Color = LiteTheme.Colors.textPrimary,
        symbolSize: CGFloat = 18
    ) {
        self.amountMinor = amountMinor
        self.currency = currency
        self.font = font
        self.color = color
        self.symbolSize = symbolSize
    }

    public var body: some View {
        let major = formatLiteMajorAmount(amountMinor: amountMinor)
        HStack(spacing: 4) {
            if currency.uppercased() == "SAR" {
                Text(LiteFonts.saudiRiyalSymbol)
                    .font(LiteFonts.saudiRiyal(size: symbolSize))
                    .foregroundColor(color)
            } else {
                Text(currency)
                    .font(font)
                    .foregroundColor(color)
            }
            Text(major)
                .font(font)
                .foregroundColor(color)
        }
    }
}
#endif
