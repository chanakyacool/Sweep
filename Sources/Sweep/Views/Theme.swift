import SwiftUI

// MARK: - Palette

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A two-stop gradient that gives each section of the app its own identity.
struct Accent: Equatable {
    let start: Color
    let end: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var angular: AngularGradient {
        AngularGradient(colors: [start, end, start], center: .center)
    }

    static let brand = Accent(start: Color(hex: 0x8B6CFF), end: Color(hex: 0x38C6FF))
}

/// Sweep's visual language: an ink-dark canvas, translucent glass surfaces and one vivid accent per section.
enum Theme {
    static let canvas = Color(hex: 0x090B12)
    static let canvasRaised = Color(hex: 0x10131D)
    static let glass = Color.white.opacity(0.05)
    static let glassStrong = Color.white.opacity(0.09)
    static let hairline = Color.white.opacity(0.09)
    static let track = Color.white.opacity(0.08)

    static let positive = Color(hex: 0x3DDC97)
    static let caution = Color(hex: 0xFFB648)
    static let critical = Color(hex: 0xFF5C7A)
    static let info = Color(hex: 0x6CB6FF)

    static let cornerRadius: CGFloat = 16

    /// Categorical colours for the disk map, drawn from the section accents.
    static let palette: [Color] = [
        Color(hex: 0x7C6CFF), Color(hex: 0x38B6FF), Color(hex: 0x2FCFB0), Color(hex: 0xFF8A5C),
        Color(hex: 0xF25C9A), Color(hex: 0xB86CFF), Color(hex: 0xF2B84B), Color(hex: 0x5C8DFF),
    ]

    static func usage(_ fraction: Double) -> Accent? {
        if fraction >= 0.9 { return Accent(start: Color(hex: 0xFF7A8F), end: critical) }
        if fraction >= 0.75 { return Accent(start: Color(hex: 0xFFD27A), end: caution) }
        return nil
    }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The icon and accent of the section currently on screen, shared with every component through the environment.
struct SectionStyle: Equatable {
    var icon = "sparkles"
    var accent = Accent.brand
}

private struct SectionStyleKey: EnvironmentKey {
    static let defaultValue = SectionStyle()
}

extension EnvironmentValues {
    var sectionStyle: SectionStyle {
        get { self[SectionStyleKey.self] }
        set { self[SectionStyleKey.self] = newValue }
    }
}

// MARK: - Backdrop & surfaces

/// The window background: near-black, lit from the corners by the active section's accent.
struct Backdrop: View {
    let accent: Accent

    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(colors: [accent.start.opacity(0.30), .clear], center: .topTrailing, startRadius: 0, endRadius: 720)
            RadialGradient(colors: [accent.end.opacity(0.16), .clear], center: .bottomLeading, startRadius: 0, endRadius: 620)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: accent)
    }
}

struct Card: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = Theme.cornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .background(Theme.glass, in: shape)
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1))
            .clipShape(shape)
    }
}

extension View {
    func card(padding: CGFloat = 18, radius: CGFloat = Theme.cornerRadius) -> some View {
        modifier(Card(padding: padding, radius: radius))
    }
}

/// A rounded tile carrying a section's icon on its gradient.
struct IconBadge: View {
    let icon: String
    let accent: Accent
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(accent.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: icon).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: accent.start.opacity(0.45), radius: size * 0.3, y: size * 0.12)
    }
}

// MARK: - Buttons

/// The main call to action: a glowing capsule filled with the section gradient.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Rendered(configuration: configuration) }

    struct Rendered: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.sectionStyle) private var style
        @State private var hovering = false

        var body: some View {
            let large = controlSize == .large
            configuration.label
                .font(.system(size: large ? 15 : 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 26 : 16)
                .padding(.vertical, large ? 11 : 7)
                .background(style.accent.gradient, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: style.accent.start.opacity(isEnabled ? (hovering ? 0.65 : 0.4) : 0), radius: hovering ? 16 : 10, y: 4)
                .scaleEffect(configuration.isPressed ? 0.96 : hovering ? 1.02 : 1)
                .opacity(isEnabled ? 1 : 0.35)
                .saturation(isEnabled ? 1 : 0.3)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// A quiet translucent capsule for secondary actions.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Rendered(configuration: configuration) }

    struct Rendered: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        var body: some View {
            let large = controlSize == .large
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, large ? 20 : 14)
                .padding(.vertical, large ? 10 : 7)
                .background(Color.white.opacity(configuration.isPressed ? 0.16 : hovering ? 0.12 : 0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.35)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle { GlassButtonStyle() }
}

// MARK: - Page chrome

/// Standard page chrome: the section badge, title and trailing actions above the page content.
struct Page<Actions: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    @Environment(\.sectionStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                IconBadge(icon: style.icon, accent: style.accent, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.display(24))
                    Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                }
                Spacer(minLength: 16)
                HStack(spacing: 10) { actions() }.buttonStyle(.glass)
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 18)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content()
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Scan orb & states

/// Sweep's signature element: a glowing orb whose ring spins while a scan is running.
struct ScanOrb: View {
    var icon: String? = nil
    var spinning = false
    var size: CGFloat = 190
    @Environment(\.sectionStyle) private var style
    @State private var rotation = 0.0
    @State private var pulse = false

    var body: some View {
        let accent = style.accent
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [accent.start.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: size * 0.72))
                .frame(width: size * 1.5, height: size * 1.5)
                .scaleEffect(spinning ? (pulse ? 1.08 : 0.92) : 1)
                .blur(radius: 18)
            Circle().strokeBorder(.white.opacity(0.06), lineWidth: 1).frame(width: size * 1.22, height: size * 1.22)
            Circle()
                .trim(from: 0, to: spinning ? 0.72 : 1)
                .stroke(accent.angular, style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(rotation))
            Circle()
                .fill(accent.gradient)
                .frame(width: size * 0.74, height: size * 0.74)
                .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)))
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .shadow(color: accent.start.opacity(0.6), radius: size * 0.16, y: size * 0.05)
            Image(systemName: icon ?? style.icon)
                .font(.system(size: size * 0.26, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .frame(width: size * 1.3, height: size * 1.3)
        .onAppear {
            // Continuous animation runs only during a scan, so an idle window costs no CPU.
            guard spinning else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulse = true }
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { rotation = 360 }
        }
    }
}

struct EmptyState<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 14) {
            ScanOrb(icon: icon, size: 150).padding(.bottom, 6)
            Text(title).font(Theme.display(26))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 470)
            action().buttonStyle(.glass).padding(.top, 10)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanningState: View {
    let title: String
    let progress: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ScanOrb(spinning: true, size: 150).padding(.bottom, 6)
            Text(title).font(Theme.display(26))
            Text(progress)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            Button("Stop", action: cancel).buttonStyle(.glass).padding(.top, 10)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Banners

private struct Banner: View {
    let icon: String
    let text: String
    let tint: Color
    var help = ""
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer()
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.glass) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .help(help)
    }
}

/// Reports the result of a removal.
struct OutcomeBanner: View {
    let outcome: Remover.Outcome

    var body: some View {
        let clean = outcome.failures.isEmpty
        Banner(icon: clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
               text: summary, tint: clean ? Theme.positive : Theme.caution,
               help: outcome.failures.prefix(12).joined(separator: "\n"))
    }

    private var summary: String {
        var text = "Freed \(Fmt.bytes(outcome.freed)) by removing \(outcome.removed) item\(outcome.removed == 1 ? "" : "s")."
        if !outcome.failures.isEmpty {
            text += " \(outcome.failures.count) could not be removed — hover for details."
        }
        return text
    }
}

struct NoticeBanner: View {
    let icon: String
    let text: String
    var tint: Color = Theme.caution
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Banner(icon: icon, text: text, tint: tint, actionTitle: actionTitle, action: action)
    }
}

// MARK: - Gauges

struct UsageBar: View {
    let fraction: Double
    var accent: Accent? = nil
    var height: CGFloat = 6
    @Environment(\.sectionStyle) private var style

    var body: some View {
        let fill = accent ?? Theme.usage(fraction) ?? style.accent
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(LinearGradient(colors: [fill.start, fill.end], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, max(0, min(1, fraction)) * geometry.size.width))
                    .shadow(color: fill.start.opacity(0.5), radius: 4)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.5), value: fraction)
    }
}

/// A circular gauge with content in its centre.
struct Ring<Center: View>: View {
    let fraction: Double
    var accent: Accent? = nil
    var lineWidth: CGFloat = 9
    @ViewBuilder var center: () -> Center
    @Environment(\.sectionStyle) private var style

    var body: some View {
        let fill = accent ?? Theme.usage(fraction) ?? style.accent
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, min(1, fraction)))
                .stroke(fill.angular, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: fill.start.opacity(0.55), radius: 6)
            center()
        }
        .padding(lineWidth / 2)
        .animation(.easeOut(duration: 0.6), value: fraction)
    }
}

struct Sparkline: View {
    let values: [Double]
    var maximum: Double? = nil
    var accent: Accent? = nil
    @Environment(\.sectionStyle) private var style

    var body: some View {
        let fill = accent ?? style.accent
        GeometryReader { geometry in
            let top = max(maximum ?? (values.max() ?? 1), 0.0001)
            let step = geometry.size.width / CGFloat(max(values.count - 1, 1))
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step, y: 2 + (geometry.size.height - 4) * (1 - CGFloat(min(value / top, 1))))
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [fill.start.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(LinearGradient(colors: [fill.start, fill.end], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: fill.start.opacity(0.6), radius: 4)
            }
        }
    }
}

// MARK: - Rows & fields

/// A round check mark that fills with the section gradient when on.
struct CheckMark: View {
    let isOn: Bool
    var isMixed = false
    let toggle: (Bool) -> Void
    @Environment(\.sectionStyle) private var style

    var body: some View {
        Button { toggle(!isOn) } label: {
            ZStack {
                Circle().fill(isOn || isMixed ? AnyShapeStyle(style.accent.gradient) : AnyShapeStyle(Color.white.opacity(0.06)))
                Circle().strokeBorder(.white.opacity(isOn || isMixed ? 0.3 : 0.22), lineWidth: 1)
                if isOn || isMixed {
                    Image(systemName: isOn ? "checkmark" : "minus").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: 19, height: 19)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOn)
    }
}

/// A selectable row used by every checklist in the app.
struct CheckRow<Trailing: View>: View {
    let isOn: Bool
    let toggle: (Bool) -> Void
    let title: String
    let subtitle: String
    var icon: NSImage? = nil
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            CheckMark(isOn: isOn, toggle: toggle)
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Color.white.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4)) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

struct SizeLabel: View {
    let bytes: Int64
    var body: some View {
        Text(Fmt.bytes(bytes)).font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
    }
}

struct Metric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.white.opacity(0.42))
                .lineLimit(1).fixedSize()
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()).lineLimit(1).fixedSize()
        }
    }
}

/// A thin divider that suits the dark canvas better than the system one.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

extension View {
    /// Asks before removing files, with wording that reflects the Trash/permanent preference.
    func removalConfirmation(isPresented: Binding<Bool>, size: Int64, count: Int, extra: String = "", perform: @escaping () -> Void) -> some View {
        let permanent = Prefs.permanentDelete
        return alert(permanent ? "Permanently delete \(Fmt.bytes(size))?" : "Move \(Fmt.bytes(size)) to the Trash?",
                     isPresented: isPresented) {
            Button(permanent ? "Delete" : "Move to Trash", role: .destructive, action: perform)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(count) item\(count == 1 ? "" : "s") will be \(permanent ? "deleted. This cannot be undone." : "moved to the Trash, where you can still restore them.")\(extra.isEmpty ? "" : "\n\n" + extra)")
        }
    }
}
