import SwiftUI

struct ContentView: View {
    @StateObject private var audioManager = AudioEngineManager()
    @State private var showSpeakerWarning = false

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
        .alert("Speaker feedback warning", isPresented: $showSpeakerWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Listen Anyway", role: .destructive) {
                audioManager.beginListening()
            }
        } message: {
            Text("Routing microphone input to a phone or tablet speaker can create loud feedback. Keep the output away from the input, or choose headphones/Bluetooth/USB output instead.")
        }
    }

    // MARK: - Header

    private var headerTitle: some View {
        Text("AnyListen")
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.95))
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

    private var speakerCard: some View {
        VStack(spacing: 10) {
            routeRow(
                title: "Speaker or Headphones",
                value: audioManager.currentOutputName,
                icon: "speaker.wave.2.fill",
                // Tint orange only when the output is genuinely MISSING
                // (i.e. the user's last AirPods/BT/USB headphones have
                // disappeared and iOS has fallen back to the speaker).
                // The "working output but feedback-prone" case keeps the
                // row in normal cyan/white tones, with the warning text
                // below handling the heads-up.
                isWarning: audioManager.outputIsMissing
            ) {
                AudioRoutePicker()
                    .frame(width: 52, height: 44)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(12)
                    .accessibilityLabel("Select output")
            }

            // Missing takes precedence over feedback: if the user's
            // preferred output is gone, that's the more urgent message.
            if audioManager.outputIsMissing {
                warningText("Selected speaker is missing. Reconnect it or choose a different output.")
            } else if audioManager.outputMayCauseFeedback {
                warningText("Speaker output can cause feedback. Use headphones, Bluetooth, or USB output when possible.")
            }
        }
        .padding(14)
        .cardStyle(borderColor: cardBorderColor(
            forWarning: audioManager.outputIsMissing || audioManager.outputMayCauseFeedback
        ))
        .animation(.easeInOut(duration: 0.25), value: audioManager.outputIsMissing)
        .animation(.easeInOut(duration: 0.25), value: audioManager.outputMayCauseFeedback)
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
    }

    // MARK: - Computed display state

    /// True when the LISTEN control is unavailable because configuration
    /// is incomplete (i.e. the user must pick a microphone first).
    private var isButtonDisabledByConfig: Bool {
        !audioManager.isRunning && audioManager.selectedInputIsMissing
    }

    private var listeningStateText: String {
        if isButtonDisabledByConfig { return "Disabled" }
        return audioManager.isRunning ? "Listening is on" : "Listening is off"
    }

    private var listeningValueColor: Color {
        if isButtonDisabledByConfig { return .orange }
        return audioManager.isRunning ? .green : .white
    }

    private var listeningRowIconColor: Color {
        if isButtonDisabledByConfig { return .orange }
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
            } else if audioManager.outputMayCauseFeedback {
                showSpeakerWarning = true
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

                    // Diagonal "no" slash for the disabled state only.
                    if isButtonDisabledByConfig {
                        Capsule()
                            .fill(Color.white.opacity(0.65))
                            .frame(width: 9, height: 124)
                            .rotationEffect(.degrees(50))
                    }
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
        .disabled(isButtonDisabledByConfig)
    }

    private var buttonLabelText: String {
        if isButtonDisabledByConfig { return "Microphone required" }
        return audioManager.isRunning ? "Stop Listening" : "Start Listening"
    }

    /// White "Stop Listening" on the iOS system-green fill is the
    /// standard treatment for an active control carrying a "stop"
    /// verb: crisp, high-readability, instantly recognizable. The word
    /// "Stop" carries the action; the green palette carries the
    /// "alive/listening" mood without any red anywhere in the active
    /// state.
    private var buttonLabelColor: Color {
        if isButtonDisabledByConfig { return Color.white.opacity(0.40) }
        return audioManager.isRunning
            ? Color.white
            : Color.green
    }

    private var buttonStrokeColor: Color {
        if isButtonDisabledByConfig { return Color.white.opacity(0.25) }
        return audioManager.isRunning ? Color.clear : Color.green.opacity(0.9)
    }

    private var buttonIconColor: Color {
        if isButtonDisabledByConfig { return Color.white.opacity(0.30) }
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
