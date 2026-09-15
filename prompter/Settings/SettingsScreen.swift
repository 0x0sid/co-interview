import SwiftUI
import SwiftData

/// Reader preferences (M5.10). Appearance and text size live here and **only** here — the editor's
/// two "A" buttons were removed and were not replaced by a second control anywhere else.
struct SettingsScreen: View {
    /// Injected so Settings and the paywall share one entitlement state.
    let entitlements: EntitlementService

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var settingsQuery: [AppSettings]

    private var settings: AppSettings { AppSettings.fetchOrCreate(in: modelContext) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        PaywallScreen(entitlements: entitlements)
                            .onAppear {
                                // Opening it clears the badge for good. It is not re-added because
                                // the reader has not subscribed.
                                if !settings.hasSeenPremiumAnnouncement {
                                    settings.hasSeenPremiumAnnouncement = true
                                    try? modelContext.save()
                                }
                            }
                    } label: {
                        HStack {
                            Label("Prompter Premium", systemImage: "sparkles")
                            Spacer()
                            if entitlements.status.allowsUnlimitedReading {
                                Text("Active")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.Color.secondary)
                            }
                            if !(settingsQuery.first?.hasSeenPremiumAnnouncement ?? false) {
                                Text("1")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 20, minHeight: 20)
                                    .background(Circle().fill(Color.red))
                            }
                        }
                    }
                    .accessibilityLabel(
                        (settingsQuery.first?.hasSeenPremiumAnnouncement ?? false)
                            ? "Prompter Premium"
                            : "Prompter Premium, 1 new item"
                    )
                }

                Section("Appearance") {
                    Picker("Appearance", selection: appearanceBinding) {
                        ForEach(AppearancePreference.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Appearance")
                }

                Section {
                    // One clearly labelled text-size control. There is no second pair of "A"
                    // buttons in the editor or anywhere else.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reading text size").font(.subheadline)
                        Slider(value: fontScaleBinding, in: 0.7...2.0, step: 0.1) {
                            Text("Reading text size")
                        } minimumValueLabel: {
                            Text("A").font(.footnote)
                        } maximumValueLabel: {
                            Text("A").font(.title3)
                        }
                        .accessibilityLabel("Reading text size")
                        Text("Sample text at this size")
                            .font(.system(size: 17 * (settingsQuery.first?.fontScale ?? 1.0)))
                            .foregroundStyle(Theme.Color.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Reading")
                } footer: {
                    Text("Applies to the reading screen. You can also pinch to zoom while reading.")
                }

                Section("Accessibility") {
                    Toggle("High-contrast outdoor mode", isOn: outdoorBinding)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // Bindings write straight through to the existing SwiftData settings record — no new storage.
    private var appearanceBinding: Binding<AppearancePreference> {
        Binding(get: { settings.appearance }, set: { settings.appearance = $0; try? modelContext.save() })
    }
    private var fontScaleBinding: Binding<Double> {
        Binding(get: { settings.fontScale }, set: { settings.fontScale = $0; try? modelContext.save() })
    }
    private var outdoorBinding: Binding<Bool> {
        Binding(get: { settings.outdoorMode }, set: { settings.outdoorMode = $0; try? modelContext.save() })
    }
}
