import ServiceManagement
import SwiftUI

@main enum Entry {
    static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case "--selftest": selftest()
        case "--status": statusProbe()
        default: TuyableApp.main()
        }
    }

    /// Headless live check: connect, read state, print, exit.
    static func statusProbe() {
        Task { @MainActor in
            let b = Bulb()
            do {
                try await b.ensureConnected()
                try await Task.sleep(for: .seconds(1))
                print("\(b.name): on=\(b.on) color=\(b.color) white=\(b.white) temp=\(b.temp) hue=\(b.hue) sat=\(b.sat) level=\(b.level)")
                exit(0)
            } catch { print("error:", error.localizedDescription); exit(1) }
        }
        dispatchMain()
    }
}

struct TuyableApp: App {
    @State private var bulb = Bulb()
    var body: some Scene {
        MenuBarExtra {
            Panel(bulb: bulb)
        } label: {
            Image(systemName: bulb.on ? "lightbulb.fill" : "lightbulb")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Panel

struct Panel: View {
    @Bindable var bulb: Bulb
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var tint: Color { bulb.color ? Color(hue: bulb.hue, saturation: bulb.sat, brightness: 1) : warmWhite(bulb.temp) }
    var lit: Color { bulb.on ? tint : Color.secondary.opacity(0.35) }

    var body: some View {
        VStack(spacing: 18) {
            header
            ModePicker(color: Binding(get: { bulb.color }, set: { $0 ? bulb.applyColor() : bulb.applyWhite() }))
            Group {
                if bulb.color { colorControls } else { whiteControls }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            LabeledSlider(title: "Brightness", icon: "sun.max.fill",
                          value: bulb.color ? $bulb.level : $bulb.white,
                          colors: [tint.opacity(0.12), tint]) { bulb.color ? bulb.applyColor() : bulb.applyWhite() }
            footer
        }
        .padding(18)
        .frame(width: 300)
        .background(alignment: .top) {
            RadialGradient(colors: [lit.opacity(bulb.on ? 0.45 : 0), .clear], center: .top, startRadius: 0, endRadius: 260)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.4), value: bulb.on)
        }
        .animation(.snappy(duration: 0.25), value: bulb.color)
        .onAppear { bulb.visible = true; atLogin = SMAppService.mainApp.status == .enabled }
        .onDisappear { bulb.visible = false }
    }

    var header: some View {
        HStack(spacing: 14) {
            Button(action: bulb.toggle) {
                ZStack {
                    Circle().fill(lit.gradient)
                        .shadow(color: bulb.on ? tint.opacity(0.8) : .clear, radius: 12)
                    Image(systemName: "power").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(bulb.on ? .black.opacity(0.65) : .white.opacity(0.9))
                }
                .frame(width: 46, height: 46)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(bulb.on ? "Turn off (Space)" : "Turn on (Space)")
            .accessibilityLabel(bulb.on ? "Turn off" : "Turn on")

            VStack(alignment: .leading, spacing: 2) {
                Text(bulb.name).font(.system(size: 14, weight: .semibold))
                status
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.3), value: bulb.on)
    }

    @ViewBuilder var status: some View {
        switch bulb.link {
        case .ready:
            Text(bulb.on ? "On · \(Int(((bulb.color ? bulb.level : bulb.white) * 100).rounded()))%" : "Off")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        case .connecting, .offline:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Connecting…") }
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            HStack(spacing: 6) {
                Text(msg).foregroundStyle(.orange).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Button("Retry", action: bulb.retry).buttonStyle(.link)
            }
            .font(.caption)
        }
    }

    var whiteControls: some View {
        VStack(spacing: 14) {
            LabeledSlider(title: "Temperature", icon: "thermometer.medium", value: $bulb.temp,
                          colors: [warmWhite(0), warmWhite(0.5), warmWhite(1)], caption: tempName(bulb.temp),
                          action: bulb.applyWhite)
            HStack(spacing: 6) {
                ForEach(whitePresets, id: \.name) { p in
                    Chip(label: p.name, color: warmWhite(p.temp)) {
                        bulb.temp = p.temp; bulb.white = p.bright; bulb.applyWhite()
                    }
                }
            }
        }
    }

    var colorControls: some View {
        VStack(spacing: 14) {
            ColorWheel(hue: $bulb.hue, sat: $bulb.sat, action: bulb.applyColor)
                .frame(width: 180, height: 180)
                .padding(.top, 2)
            HStack(spacing: 0) {
                ForEach(colorPresets, id: \.self) { h in
                    Button {
                        bulb.hue = h; bulb.sat = 1; bulb.applyColor()
                    } label: {
                        Circle().fill(Color(hue: h, saturation: 1, brightness: 1).gradient)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.white.opacity(abs(bulb.hue - h) < 0.01 && bulb.sat > 0.98 ? 0.95 : 0.15), lineWidth: 2))
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    var footer: some View {
        HStack {
            Toggle("Open at Login", isOn: $atLogin)
                .toggleStyle(.checkbox)
                .onChange(of: atLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    atLogin = SMAppService.mainApp.status == .enabled
                }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.link).keyboardShortcut("q")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

let whitePresets: [(name: String, temp: Double, bright: Double)] =
    [("Candle", 0, 0.25), ("Relax", 0.2, 0.6), ("Read", 0.55, 1), ("Focus", 1, 1)]
let colorPresets: [Double] = [0, 0.05, 0.11, 0.3, 0.5, 0.62, 0.75, 0.88]

func warmWhite(_ t: Double) -> Color {
    // 0 = ~2700K amber, 1 = ~6500K icy
    let (w, c) = ((1.0, 0.70, 0.40), (0.80, 0.89, 1.0))
    return Color(red: w.0 + (c.0 - w.0) * t, green: w.1 + (c.1 - w.1) * t, blue: w.2 + (c.2 - w.2) * t)
}

func tempName(_ t: Double) -> String { t < 0.2 ? "Warm" : t < 0.45 ? "Soft" : t < 0.7 ? "Neutral" : "Cool" }

// MARK: - Components

struct ModePicker: View {
    @Binding var color: Bool
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            seg("White", "sun.max", false)
            seg("Color", "paintpalette", true)
        }
        .padding(3)
        .background(Capsule().fill(.primary.opacity(0.07)))
    }

    func seg(_ title: String, _ icon: String, _ value: Bool) -> some View {
        Button { color = value } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 26)
                .foregroundStyle(color == value ? .primary : .secondary)
                .background {
                    if color == value {
                        Capsule().fill(.background.opacity(0.9)).shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "pill", in: ns)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct LabeledSlider: View {
    let title: String, icon: String
    @Binding var value: Double
    let colors: [Color]
    var caption: String? = nil
    let action: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Label(title, systemImage: icon).labelStyle(.titleAndIcon)
                Spacer()
                Text(caption ?? "\(Int((value * 100).rounded()))%").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            GradientSlider(value: $value, colors: colors, action: action)
        }
    }
}

struct GradientSlider: View {
    @Binding var value: Double
    let colors: [Color]
    let action: () -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let h = g.size.height, span = g.size.width - h
            ZStack {
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                Circle().fill(.white)
                    .frame(width: h - 6, height: h - 6)
                    .shadow(color: .black.opacity(0.25), radius: dragging ? 4 : 2, y: 1)
                    .scaleEffect(dragging ? 1.08 : 1)
                    .position(x: h / 2 + value * span, y: h / 2)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    value = min(1, max(0, (v.location.x - h / 2) / span))
                    action()
                }
                .onEnded { _ in dragging = false })
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 26)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { value = $0; action() }), in: 0...1)
        }
    }
}

struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var sat: Double
    let action: () -> Void

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2, c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let a = hue * 2 * .pi
            ZStack {
                // SwiftUI angles run clockwise from east (y-down), matching atan2 below.
                Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) },
                                              center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: r))
                Circle().strokeBorder(.primary.opacity(0.08))
                Circle().fill(Color(hue: hue, saturation: sat, brightness: 1))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .position(x: c.x + cos(a) * sat * r, y: c.y + sin(a) * sat * r)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let dx = v.location.x - c.x, dy = v.location.y - c.y
                let h = atan2(dy, dx) / (2 * .pi)
                hue = h < 0 ? h + 1 : h
                sat = min(1, hypot(dx, dy) / r)
                action()
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Color")
        .accessibilityValue("Hue \(Int(hue * 360)) degrees, saturation \(Int(sat * 100)) percent")
        .accessibilityAdjustableAction { dir in
            hue = (hue + (dir == .increment ? 1 : -1) / 36 + 1).truncatingRemainder(dividingBy: 1); action()
        }
    }
}

struct Chip: View {
    let label: String, color: Color, action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(color.gradient).frame(width: 7, height: 7)
                Text(label).lineLimit(1).fixedSize()
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 4).frame(height: 24)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(.primary.opacity(hover ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
