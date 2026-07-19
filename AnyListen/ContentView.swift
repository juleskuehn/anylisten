import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var audioManager = AudioEngineManager()
    @State private var showSettings = false

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
                VStack(spacing: 12) {
                    headerTitle
                        .padding(.top, 8)

                    microphoneCard
                    speakerCard
                    listeningCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            audioManager.updateAudioRoutes()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(audioManager: audioManager)
        }
        .onChange(of: audioManager.isRunning) { newValue in
            UIAccessibility.post(notification: .announcement,
                                 argument: newValue ? "Listening started" : "Listening stopped")
        }
    }

    // MARK: - Header

    private var headerTitle: some View {
        HStack {
            Text("AnyListen")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.95))
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .accessibilityLabel("Settings")
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
            ) {
                inputMenu
            }

            // Contextual warning lives inside the microphone card, since it
            // is exclusively about a missing microphone.
            if audioManager.selectedInputIsMissing {
                warningText("Selected microphone is missing. Reconnect it or choose another input.")
            }
        }
        .padding(14)
        .cardStyle(borderColor: cardBorderColor(forWarning: audioManager.selectedInputIsMissing))
        .animation(.easeInOut(duration: 0.25), value: audioManager.selectedInputIsMissing)
    }

    private var outputValueText: String {
        if audioManager.isDangerousLoopback {
            return "Connect headphones"
        }
        return audioManager.currentOutputName
    }

    private var speakerCard: some View {
        VStack(spacing: 10) {
            routeRow(
                title: "Speaker or Headphones",
                value: outputValueText,
                icon: "speaker.wave.2.fill",
                // Tint orange when the output is genuinely missing OR in
                // the blocked dangerous feedback state (iPhone mic →
                // iPhone speaker). Same-device routing is permanently
                // disabled, so this row itself is the call-to-action:
                // "Connect headphones".
                isWarning: audioManager.outputIsMissing || audioManager.isDangerousLoopback
            ) {
                AudioRoutePicker()
                    .frame(width: 52, height: 44)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(12)
                    .accessibilityLabel("Select output")
            }

            if audioManager.outputIsMissing {
                warningText("Selected speaker is missing. Reconnect it or choose a different output.")
            }
        }
        .padding(14)
        .cardStyle(borderColor: cardBorderColor(
            forWarning: audioManager.outputIsMissing || audioManager.isDangerousLoopback
        ))
        .animation(.easeInOut(duration: 0.25), value: audioManager.outputIsMissing)
        .animation(.easeInOut(duration: 0.25), value: audioManager.isDangerousLoopback)
    }

    private var listeningCard: some View {
        VStack(spacing: 12) {
            // Title row mirrors the routeRow pattern so the three cards
            // share a consistent visual rhythm (icon + small label + state).
            HStack(spacing: 12) {
                Image(systemName: "ear")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(listeningRowIconColor)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Listening Control")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                    Text(listeningStateText)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(listeningValueColor)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }

                Spacer(minLength: 8)
            }
            .frame(minHeight: 54)

            listenButton

            // Operational / engine errors (route changed, interrupted,
            // system reset, etc.) land here — errors that don't belong to
            // either the input or output card individually.
            if let errorMessage = audioManager.errorMessage {
                warningText(errorMessage)
            }
        }
        .padding(14)
        .cardStyle(borderColor: listeningCardBorderColor)
        .animation(.easeInOut(duration: 0.25), value: audioManager.isRunning)
        .animation(.easeInOut(duration: 0.25), value: audioManager.errorMessage)
        .animation(.easeInOut(duration: 0.25), value: audioManager.isDangerousLoopback)
    }

    // MARK: - Computed display state

    /// True when the selected mic is missing (must pick/reattach a mic).
    private var inputMissing: Bool {
        !audioManager.isRunning && audioManager.selectedInputIsMissing
    }

    /// True when the only available path is iPhone mic → iPhone speaker
    /// AND the user has not opted into same-device loopback. This is the
    /// feedback-prone default that nobody wants; the button is disabled
    /// with constructive guidance instead of a scary confirm.
    private var isDangerousBlocked: Bool {
        !audioManager.isRunning && audioManager.isDangerousLoopback
    }

    /// True when the LISTEN control is unavailable (missing mic, or
    /// dangerous same-device loopback that hasn't been opted into).
    private var isButtonDisabled: Bool {
        !audioManager.isRunning && (audioManager.selectedInputIsMissing || isDangerousBlocked)
    }

    private var listeningStateText: String {
        return audioManager.isRunning ? "Listening is on" : "Listening is off"
    }

    private var listeningValueColor: Color {
        return audioManager.isRunning ? .green : .white
    }

    private var listeningRowIconColor: Color {
        return audioManager.isRunning ? .green : .cyan
    }

    /// Listening card border: green when actively listening, orange when
    /// there is a contextual operational error, otherwise the standard
    /// subtle white.
    private var listeningCardBorderColor: Color {
        if audioManager.isRunning { return Color.green.opacity(0.45) }
        if audioManager.errorMessage != nil { return Color.orange.opacity(0.45) }
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
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
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
        .accessibilityLabel(audioManager.isRunning ? "Stop listening" : "Start listening")
        .accessibilityHint(audioManager.isRunning
            ? "Stops routing microphone audio to your output"
            : "Starts routing microphone audio to your output")
        .accessibilityValue(audioManager.isRunning ? "on" : "off")
    }

    private var buttonLabelText: String {
        if isDangerousBlocked { return "Headphones required" }
        if inputMissing { return "Microphone required" }
        return audioManager.isRunning ? "Stop Listening" : "Start Listening"
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

    private func routeRow<Control: View>(
        title: String,
        value: String,
        icon: String,
        isWarning: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isWarning ? .orange : .cyan)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(isWarning ? .orange : .white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 54)
    }

    // MARK: - Subviews

    private var inputMenu: some View {
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
            HStack(spacing: 6) {
                Text("Change")
                    .font(.system(size: 15, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(width: 118, height: 44)
            .background(Color.white.opacity(0.12))
            .cornerRadius(12)
        }
    }

    private func warningText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30) // Matches the 30pt width of the main category icons above!
            
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.orange)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func cardBorderColor(forWarning warning: Bool) -> Color {
        warning ? Color.orange.opacity(0.45) : Color.white.opacity(0.10)
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
                    Text("When a phone call or other interruption ends, the app will automatically start listening again if it was running before.")
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
