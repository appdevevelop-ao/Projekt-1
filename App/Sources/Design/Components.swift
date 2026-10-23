import LernKern
import SwiftUI

/// Karte mit ruhigem Hintergrund.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.spacing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

struct CardTitle: View {
    var title: String
    var symbol: String?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.tint) }
            Text(title).font(.headline)
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Fortschrittsring mit Prozentangabe.
struct ProgressRing: View {
    var fraction: Double
    var label: String?
    var lineWidth: CGFloat = 10
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            if let label {
                Text(label).font(.system(.headline, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "\(Int(fraction * 100)) Prozent")
    }
}

struct LinearBar: View {
    var fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(tint).frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

struct Pill: View {
    var text: String
    var symbol: String?
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .background(Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.18 : 0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct BannerView: View {
    var banner: Banner
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.subheadline.weight(.semibold))
                Text(banner.message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
                .accessibilityLabel("Hinweis schließen")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch banner.kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .info: return .accentColor
        case .success: return Theme.success
        case .warning: return Theme.warning
        }
    }
}

/// Kennzeichnung der Herkunft (KI-Vorschlag vs. bestätigt).
struct OriginBadge: View {
    var origin: ContentOrigin
    var status: ReviewStatus

    var body: some View {
        switch (origin, status) {
        case (.ai, .suggested): Pill(text: "KI-Vorschlag", symbol: "sparkles", tint: .purple)
        case (.local, .suggested): Pill(text: "Erkannt", symbol: "doc.text.magnifyingglass", tint: .secondary)
        case (.syllabus, _): Pill(text: "Lehrplan", symbol: "list.bullet.clipboard", tint: .blue)
        case (_, .confirmed): Pill(text: "Bestätigt", symbol: "checkmark", tint: Theme.success)
        default: EmptyView()
        }
    }
}

struct LevelBadge: View {
    var level: MasteryLevel

    var body: some View {
        Pill(text: level.title, symbol: level.symbolName, tint: level.tint)
    }
}

extension MasteryLevel {
    var symbolName: String {
        switch self {
        case .notStarted: return "circle"
        case .learned: return "circle.lefthalf.filled"
        case .provisional: return "checkmark.circle"
        case .stable: return "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notStarted: return .secondary
        case .learned: return .orange
        case .provisional: return .accentColor
        case .stable: return Theme.success
        }
    }
}

extension View {
    /// Begrenzte Lesebreite auf dem iPad.
    func readableWidth() -> some View {
        frame(maxWidth: Theme.maxReadableWidth).frame(maxWidth: .infinity)
    }
}
