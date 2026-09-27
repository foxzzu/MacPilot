import SwiftUI

/// Trackpad preferences as a sheet: tracking speed, scroll direction, tap to
/// click, inertia — plus the gesture legend, because nobody guesses
/// "two-finger tap = right click" on their own.
struct TrackpadSettingsView: View {
    @ObservedObject var model: RemoteTrackpadModel
    @EnvironmentObject private var appModel: RemoteAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPressureHint = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(appModel.text("trackpadTrackingSpeed"))
                        Slider(
                            value: Binding(
                                get: { model.settings.trackingSpeed },
                                set: { model.settings.trackingSpeed = $0 }
                            ),
                            in: 0.5...2
                        )
                    }
                    Toggle(
                        appModel.text("trackpadNaturalScrolling"),
                        isOn: Binding(
                            get: { model.settings.naturalScrolling },
                            set: { model.settings.naturalScrolling = $0 }
                        )
                    )
                    Toggle(
                        appModel.text("trackpadTapToClick"),
                        isOn: Binding(
                            get: { model.settings.tapToClick },
                            set: { model.settings.tapToClick = $0 }
                        )
                    )
                    Toggle(
                        appModel.text("trackpadScrollInertia"),
                        isOn: Binding(
                            get: { model.settings.scrollInertia },
                            set: { model.settings.scrollInertia = $0 }
                        )
                    )
                } header: {
                    Text(appModel.text("trackpadSettings"))
                } footer: {
                    Text(appModel.text("trackpadGesturesHint"))
                }

                pressureSection
            }
            .navigationTitle(appModel.text("trackpadTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(appModel.text("trackpadDone")) { dismiss() }
                }
            }
            .alert(
                appModel.text("trackpadPressureHintTitle"),
                isPresented: $showPressureHint
            ) {
                Button(appModel.text("trackpadDone")) {}
            } message: {
                Text(appModel.text("trackpadPressureHintBody"))
            }
        }
        .presentationDetents([.medium])
    }

    /// Pressure simulation ships off and stays out of the pipeline until it
    /// is switched on here; the change lands on the very next touch.
    @ViewBuilder
    private var pressureSection: some View {
        Section {
            Picker(
                appModel.text("trackpadPressure"),
                selection: Binding(
                    get: { model.settings.pressureMode },
                    set: { model.settings.pressureMode = $0 }
                )
            ) {
                Text(appModel.text("trackpadPressureOff")).tag(PressureMode.off)
                Text(appModel.text("trackpadPressureLight")).tag(PressureMode.light)
                Text(appModel.text("trackpadPressureStandard")).tag(PressureMode.standard)
                Text(appModel.text("trackpadPressureStrong")).tag(PressureMode.strong)
            }
            .pickerStyle(.segmented)
            .onChange(of: model.settings.pressureMode) { _, newValue in
                if model.shouldShowPressureHint(for: newValue) {
                    showPressureHint = true
                }
            }
            if model.settings.pressureMode != .off {
                Toggle(
                    appModel.text("trackpadPressureFeedback"),
                    isOn: Binding(
                        get: { model.settings.pressureFeedback },
                        set: { model.settings.pressureFeedback = $0 }
                    )
                )
                Toggle(
                    appModel.text("trackpadDebugInfo"),
                    isOn: Binding(
                        get: { model.settings.pressureDebug },
                        set: { model.settings.pressureDebug = $0 }
                    )
                )
            }
        } header: {
            Text(appModel.text("trackpadPressure"))
        } footer: {
            Text(appModel.text("trackpadPressureFooter"))
        }
    }
}
