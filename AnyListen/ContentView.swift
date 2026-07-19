import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var audioManager = AudioEngineManager()
    @State private var showSettings = false

    // Dynamic Type: every text size scales with the user's preferred text
    // size (relative to the body style). Each value is the exact size the
    // layout used before scaling was added, so the default ("Large")
    // appearance is unchanged — scaling only takes effect at other sizes.
    @ScaledMetric(relativeTo: .body) private var titleFontSize = 20.0
    @ScaledMetric(relativeTo: .body) private var sectionLabelFontSize = 12.0
    @ScaledMetric(relativeTo: .body) private var valueFontSize = 17.0
    @ScaledMetric(relativeTo: .body) private var bodyFontSize = 15.0
    @ScaledMetric(relativeTo: .body) private var buttonLabelFontSize = 19.0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.13, blue: 0.18),
                    Color(red: 0.14, green: 0.18, blue: 0.24)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // ScrollView so the layout gracefully handles larger Dynamic Type
            // sizes (senior-friendly) without pushing the listen button off-screen.
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    headerTitle
                        .padding(.top, 16)
                        .padding(.bottom, 6)

                    if microphonePermissionDenied {
                        microphonePermissionCard
                    }
                    microphoneCard
                    speakerCard
                    listeningCard
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            audioManager.updateAudioRoutes()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(audioManager: audioManager)
        }
        .onChange(of: audioManager.isRunning) { _, newValue in
            UIAccessibility.post(notification: .announcement,
                                 argument: newValue
                                    ? String(localized: "Listening started")
                                    : String(localized: "Listening stopped"))
        }
    }

    // MARK: - Header

    private var headerTitle: some View {
        HStack {
            Text("AnyListen")
                .font(.system(size: titleFontSize, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.95))
                .padding(.leading, 8)
            Spacer()
            // Settings button: a full 44×44 touch target (HIG / WCAG
            // minimum), no decorative backdrop — just the glyph, made
            // slightly larger so it carries its own visual weight. The
            // larger spacing above and below gives clear separation from
            // the "Change" button on the microphone card.
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Settings"))
        }
    }

    // MARK: - Cards

    private var microphoneCard: some View {
        VStack(spacing: 10) {
            routeRow(
                title: "Microphone",
                value: audioManager.currentInputName,
                icon: "mic.fill",
                isWarning: audioManager.selectedInputIsMissing
            ) { expanded in
                inputMenu(expanded: expanded)
            }
        }
        .padding(14)
        .cardStyle(borderColor: Color.white.opacity(0.10))
    }

    private var outputValueText: String {
        if audioManager.outputIsBlocked {
            return String(localized: "Connect headphones")
        }
        return audioManager.currentOutputName
    }

    private var speakerCard: some View {
        VStack(spacing: 10) {
            routeRow(
                title: "Speaker or headphones",
                value: outputValueText,
                icon: "speaker.wave.2.fill",
                isWarning: audioManager.outputIsMissing || audioManager.outputIsBlocked
            ) { expanded in
                outputPickerControl(expanded: expanded)
            }
        }
        .padding(14)
        .cardStyle(borderColor: Color.white.opacity(0.10))
    }

    // MARK: - Microphone permission card

    /// Shown only when mic permission is denied/restricted — the one
    /// state where the orange in-row warnings and the disabled Listen
    /// button can't explain the situation or offer a way out. This is
    /// deliberately NOT driven by `errorMessage` (which stays hidden);
    /// it reacts directly to the permission status.
    private var microphonePermissionCard: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Microphone access")
                    .font(.system(size: sectionLabelFontSize, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.orange)
                        .frame(width: 30)
                        .accessibilityHidden(true)

                    Text("Microphone access is turned off. AnyListen needs the microphone to route audio — turn it on in Settings.")
                        .font(.system(size: bodyFontSize))
                        .foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)
                }
            }

            Button {
                openSystemSettings()
            } label: {
                Text("Open Settings")
                    .font(.system(size: bodyFontSize, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.orange)
                    .cornerRadius(12)
            }
            .accessibilityHint(Text("Opens the AnyListen page in the Settings app"))
        }
        .padding(14)
        .cardStyle(borderColor: Color.orange.opacity(0.45))
    }

    /// Opens this app's page in the iOS Settings app so the user can
    /// re-enable microphone access after denying it.
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var listeningCard: some View {
        VStack(spacing: 12) {
            // Title spans the card's full width (same pattern as routeRow);
            // the state line sits below with its icon.
            VStack(alignment: .leading, spacing: 6) {
                Text("Listening control")
                    .font(.system(size: sectionLabelFontSize, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                HStack(spacing: 12) {
                    Image(systemName: "ear")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(listeningRowIconColor)
                        .frame(width: 30)
                    Text(listeningStateText)
                        .font(.system(size: valueFontSize, weight: .semibold))
                        .foregroundColor(listeningValueColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 54)

            listenButton
        }
        .padding(14)
        .cardStyle(borderColor: listeningCardBorderColor)
        .animation(.easeInOut(duration: 0.25), value: audioManager.isRunning)
        .animation(.easeInOut(duration: 0.25), value: audioManager.outputIsBlocked)
    }

    // MARK: - Computed display state

    /// True when the selected mic is missing (must pick/reattach a mic).
    private var inputMissing: Bool {
        !audioManager.isRunning && audioManager.selectedInputIsMissing
    }

    /// True when the previously routed external output was observed
    /// going away ("X — missing").
    private var outputMissing: Bool {
        !audioManager.isRunning && audioManager.outputIsMissing
    }

    /// True when the output is the iPhone speaker. Listening requires
    /// headphones (or another external output), so the button is
    /// disabled with constructive guidance instead of a scary confirm.
    private var outputBlocked: Bool {
        !audioManager.isRunning && audioManager.outputIsBlocked
    }

    /// True when listening can't start because of the output side:
    /// the external output is missing, or the speaker route is blocked.
    private var headphonesNeeded: Bool {
        outputMissing || outputBlocked
    }

    /// True when mic permission has been denied or is restricted — the
    /// one state that gets a dedicated permission card with a path back
    /// to Settings. `notDetermined` is NOT included: tapping LISTEN is
    /// what triggers the system prompt in that case.
    private var microphonePermissionDenied: Bool {
        audioManager.microphonePermissionStatus == .denied
            || audioManager.microphonePermissionStatus == .restricted
    }

    /// True when the LISTEN control is unavailable (mic permission off,
    /// missing mic, missing output, or the blocked speaker route).
    private var isButtonDisabled: Bool {
        !audioManager.isRunning && (
            microphonePermissionDenied ||
            audioManager.selectedInputIsMissing ||
            audioManager.outputIsMissing ||
            outputBlocked
        )
    }

    private var listeningStateText: String {
        return audioManager.isRunning
            ? String(localized: "Listening is on")
            : String(localized: "Listening is off")
    }

    private var listeningValueColor: Color {
        return audioManager.isRunning ? .green : .white
    }

    private var listeningRowIconColor: Color {
        return audioManager.isRunning ? .green : .cyan
    }

    /// Listening card border: green when actively listening, otherwise the standard
    /// subtle white.
    private var listeningCardBorderColor: Color {
        if audioManager.isRunning { return Color.green.opacity(0.45) }
        return Color.white.opacity(0.10)
    }

    // MARK: - Listen button

    private var listenButton: some View {
        Button {
            if audioManager.isRunning {
                audioManager.stop()
            } else {
                audioManager.beginListening()
            }
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    // Filled green only when actively listening.
                    Circle()
                        .fill(audioManager.isRunning ? Color.green : Color.clear)
                        .frame(width: 132, height: 132)
                        .shadow(
                            color: audioManager.isRunning ? Color.green.opacity(0.45) : .clear,
                            radius: 16, y: 0
                        )

                    // Hollow stroke for the "ready" and "disabled" states.
                    Circle()
                        .stroke(buttonStrokeColor, lineWidth: 3)
                        .frame(width: 132, height: 132)

                    Image(systemName: "ear")
                        .font(.system(size: 58, weight: .regular))
                        .foregroundColor(buttonIconColor)
                        .accessibilityHidden(true)
                }
                .animation(.easeInOut(duration: 0.25), value: audioManager.isRunning)
                .animation(.easeInOut(duration: 0.25), value: audioManager.selectedInputIsMissing)

                Text(buttonLabelText)
                    .font(.system(size: buttonLabelFontSize, weight: .semibold, design: .rounded))
                    .foregroundColor(buttonLabelColor)
                    .animation(.easeInOut(duration: 0.25), value: audioManager.isRunning)
                    .animation(.easeInOut(duration: 0.25), value: audioManager.selectedInputIsMissing)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isButtonDisabled)
        .accessibilityLabel(audioManager.isRunning
            ? String(localized: "Stop listening")
            : String(localized: "Start listening"))
        .accessibilityHint(audioManager.isRunning
            ? String(localized: "Stops routing microphone audio to your output")
            : String(localized: "Starts routing microphone audio to your output"))
        .accessibilityValue(audioManager.isRunning
            ? String(localized: "on", comment: "Accessibility value: listening is on")
            : String(localized: "off", comment: "Accessibility value: listening is off"))
    }

    private var buttonLabelText: String {
        if microphonePermissionDenied { return String(localized: "Microphone required") }
        if inputMissing && headphonesNeeded { return String(localized: "Headphones and microphone required") }
        if inputMissing { return String(localized: "Microphone required") }
        if headphonesNeeded { return String(localized: "Headphones required") }
        return audioManager.isRunning
            ? String(localized: "Stop Listening")
            : String(localized: "Start Listening")
    }

    /// White "Stop Listening" on the iOS system-green fill is the
    /// standard treatment for an active control carrying a "stop"
    /// verb: crisp, high-readability, instantly recognizable. The word
    /// "Stop" carries the action; the green palette carries the
    /// "alive/listening" mood without any red anywhere in the active
    /// state.
    private var buttonLabelColor: Color {
        if isButtonDisabled { return Color.white.opacity(0.60) }
        return audioManager.isRunning
            ? Color.white
            : Color.green
    }

    private var buttonStrokeColor: Color {
        if isButtonDisabled { return Color.white.opacity(0.35) }
        return audioManager.isRunning ? Color.clear : Color.green.opacity(0.9)
    }

    private var buttonIconColor: Color {
        if isButtonDisabled { return Color.white.opacity(0.45) }
        return audioManager.isRunning ? .white : Color.green.opacity(0.9)
    }



    // MARK: - Route row (shared by mic + speaker cards)

    /// Card layout: the muted title spans the card's full width on its own
    /// line; below it, the icon + value + control row. When that row can't
    /// fit (extreme Dynamic Type sizes), ViewThatFits drops the control to
    /// a full-width line below — control text never wraps mid-word.
    private func routeRow<Control: View>(
        title: LocalizedStringKey,
        value: String,
        icon: String,
        isWarning: Bool,
        @ViewBuilder control: (_ expanded: Bool) -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: sectionLabelFontSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))

            ViewThatFits {
                HStack(spacing: 12) {
                    rowIcon(icon, isWarning: isWarning)
                    rowValue(value, isWarning: isWarning)
                    Spacer(minLength: 8)
                    control(false)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        rowIcon(icon, isWarning: isWarning)
                        rowValue(value, isWarning: isWarning)
                        Spacer(minLength: 8)
                    }
                    control(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 54)
    }

    private func rowIcon(_ name: String, isWarning: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(isWarning ? .orange : .cyan)
            .frame(width: 30)
            .accessibilityHidden(true)
    }

    private func rowValue(_ value: String, isWarning: Bool) -> some View {
        Text(value)
            .font(.system(size: valueFontSize, weight: .semibold))
            .foregroundColor(isWarning ? .orange : .white)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The route picker button: 52×44 in the compact row, full-width when
    /// the row has wrapped at extreme text sizes.
    private func outputPickerControl(expanded: Bool) -> some View {
        Group {
            if expanded {
                AudioRoutePicker()
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                AudioRoutePicker()
                    .frame(width: 52, height: 44)
            }
        }
        .background(Color.white.opacity(0.12))
        .cornerRadius(12)
        .accessibilityLabel(Text("Select output"))
    }

    // MARK: - Subviews

    private func inputMenu(expanded: Bool) -> some View {
        Menu {
            Button {
                audioManager.clearSelectedInput()
            } label: {
                Label("Automatic", systemImage: audioManager.selectedInputID == nil ? "checkmark" : "circle")
            }

            if !audioManager.availableInputs.isEmpty {
                Divider()
            }

            ForEach(audioManager.availableInputs) { input in
                Button {
                    audioManager.selectInput(input)
                } label: {
                    if audioManager.selectedInputID == input.id {
                        Label("\(input.name) · \(input.typeName)", systemImage: "checkmark")
                    } else {
                        Text("\(input.name) · \(input.typeName)")
                    }
                }
            }
        } label: {
            Group {
                if expanded {
                    menuLabel.frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    menuLabel.frame(minWidth: 118, minHeight: 44)
                }
            }
            .background(Color.white.opacity(0.12))
            .cornerRadius(12)
        }
    }

    /// "Change ⌄" label content, factored out so the menu can present it
    /// compact (fixed 118pt pill) or expanded (full-width bar).
    private var menuLabel: some View {
        HStack(spacing: 6) {
            Text("Change")
                .font(.system(size: bodyFontSize, weight: .semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
    }

}

// MARK: - Card styling

private extension View {
    /// Apply the consistent card chrome: translucent fill, 1pt border, and
    /// 20pt corner radius. Border color is parameterized so each card can
    /// highlight itself in orange (warnings) or stay neutral.
    func cardStyle(borderColor: Color) -> some View {
        self.background(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(borderColor, lineWidth: 1)
            )
            .cornerRadius(20)
    }
}

// MARK: - Settings

struct SettingsView: View {
    /// Hosted from this repo via GitHub Pages (`docs/privacy.html`). Must
    /// match the privacy URL entered in App Store Connect — see
    /// [`docs/APP_STORE.md`](../docs/APP_STORE.md).
    private static let privacyPolicyURL = URL(string: "https://juleskuehn.github.io/anylisten/privacy.html")!

    @ObservedObject var audioManager: AudioEngineManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                            .foregroundColor(.gray)
                        Slider(value: $audioManager.monitorVolume, in: 0.0...1.0)
                            .tint(.green)
                            .accessibilityLabel(Text("Monitor volume"))
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundColor(.gray)
                    }
                } header: {
                    Text("Volume")
                } footer: {
                    Text("Adjusts the volume of the sound sent to your headphones. This can only decrease the volume; use your iPhone's physical volume buttons to increase the maximum sound level.")
                }

                Section {
                    Toggle("Start listening automatically", isOn: $audioManager.autoListenEnabled)
                        .tint(.green)
                } header: {
                    Text("Automatic Start")
                } footer: {
                    Text("When your microphone and headphones are both connected, the app will start listening automatically. In some cases, you might need to open the app again.")
                }

                Section {
                    Toggle("Resume after phone calls", isOn: $audioManager.autoResumeEnabled)
                        .tint(.green)
                } header: {
                    Text("Phone Calls")
                } footer: {
                    Text("When a phone call or other interruption ends, the app will automatically start listening again.")
                }

                Section {
                    Link(destination: Self.privacyPolicyURL) {
                        Text("Privacy Policy")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("AnyListen does not collect any data. All audio stays on your device.")
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
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
