/*
 RAVE Engine — the guardian's settings as SwiftUI rows: the switch, when it
 shows, the safety margins, what it watches, and how it looks. Content only,
 no container, so it drops into a `Form` section (spatial-ai-character) or a
 plain stack (Longwave's PCVR panels) alike.
 */

#if canImport(SwiftUI)

import SwiftUI

public struct RAVEGuardianSettingsControls: View {
    @Bindable private var store: RAVEGuardianSettingsStore
    /// Whether this app has tracked controllers worth a toggle.
    private let offersControllers: Bool

    public init(store: RAVEGuardianSettingsStore = .shared, offersControllers: Bool = true) {
        self.store = store
        self.offersControllers = offersControllers
    }

    public var body: some View {
        Toggle("Guardian", isOn: $store.settings.isEnabled)
        if store.settings.isEnabled {
            Text("Wall cues appear briefly when a hand or controller accelerates toward a wall.")
                .font(.caption)
                .foregroundStyle(.secondary)

            slider("Safety margin", value: $store.settings.warningDistance,
                   in: RAVEGuardianSettings.warningDistanceRange, step: 0.05) {
                "\(Int(($0 * 100).rounded())) cm"
            }
            slider("Minimum approach speed", value: $store.settings.minimumApproachSpeed,
                   in: RAVEGuardianSettings.approachSpeedRange, step: 0.05) {
                String(format: "%.2f m/s", $0)
            }
            slider("Minimum acceleration", value: $store.settings.minimumApproachAcceleration,
                   in: RAVEGuardianSettings.approachAccelerationRange, step: 0.25) {
                String(format: "%.1f m/s²", $0)
            }
            slider("Prediction time", value: $store.settings.lookahead,
                   in: RAVEGuardianSettings.lookaheadRange, step: 0.05) {
                $0 == 0 ? "Off" : String(format: "%.2f s ahead", $0)
            }

            Toggle("Watch my hands", isOn: $store.settings.watchesHands)
            if offersControllers {
                Toggle("Watch controllers", isOn: $store.settings.watchesControllers)
            }
            Toggle("Show nearby furniture holograms", isOn: $store.settings.includesFurniture)
            if store.settings.includesFurniture {
                slider("Hologram brightness", value: $store.settings.appearance.obstacleOpacity,
                       in: 0.05...0.8, step: 0.05) {
                    "\(Int(($0 * 100).rounded()))%"
                }
            }

            Picker("Style", selection: $store.settings.appearance.style) {
                ForEach(RAVEGuardianSettings.Style.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            colorRow
            slider("Grid spacing", value: $store.settings.appearance.spacing,
                   in: RAVEGuardianSettings.Appearance.spacingRange, step: 0.05) {
                "\(Int(($0 * 100).rounded())) cm"
            }
            slider("Line width", value: $store.settings.appearance.lineWidth,
                   in: RAVEGuardianSettings.Appearance.lineWidthRange, step: 0.002) {
                String(format: "%.1f cm", $0 * 100)
            }
            slider("Brightness", value: $store.settings.appearance.maxOpacity, in: 0.1...1, step: 0.05) {
                "\(Int(($0 * 100).rounded()))%"
            }
            Button("Reset guardian to defaults") { store.resetToDefaults() }
        }
    }

    private var colorRow: some View {
        HStack(spacing: 10) {
            Text("Color")
            Spacer()
            ForEach(RAVEGuardianSettings.Color.presets, id: \.name) { preset in
                let selected = preset.color == store.settings.appearance.color
                Button {
                    store.settings.appearance.color = preset.color
                } label: {
                    Circle()
                        .fill(Self.swiftUIColor(preset.color))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 3 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                .labelsHidden()
        }
    }

    private var customColor: Binding<Color> {
        Binding {
            Self.swiftUIColor(store.settings.appearance.color)
        } set: { color in
            let r = color.resolve(in: EnvironmentValues())
            store.settings.appearance.color = .init(red: max(0, min(1, r.red)),
                                                   green: max(0, min(1, r.green)),
                                                   blue: max(0, min(1, r.blue)))
        }
    }

    private static func swiftUIColor(_ c: RAVEGuardianSettings.Color) -> Color {
        Color(.sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue))
    }

    private func slider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>,
                        step: Float, format: @escaping (Float) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

#endif
