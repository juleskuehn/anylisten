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
            
            VStack(spacing: 14) {
                Text("AnyListen")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.95))
                    .padding(.top, 8)
                
                settingsCard
                
                listenButton
                    .padding(.vertical, 6)
                
                statusArea
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
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
    
    private var settingsCard: some View {
        VStack(spacing: 10) {
            routeRow(
                title: "INPUT",
                value: audioManager.currentInputName,
                icon: "mic.fill",
                isWarning: audioManager.selectedInputIsMissing
            ) {
                inputMenu
            }
            
            Divider()
                .background(Color.white.opacity(0.12))
            
            routeRow(
                title: "OUTPUT",
                value: audioManager.currentOutputName,
                icon: "speaker.wave.2.fill",
                isWarning: audioManager.outputMayCauseFeedback
            ) {
                AudioRoutePicker()
                    .frame(width: 118, height: 44)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(12)
            }
            
            if audioManager.outputMayCauseFeedback {
                warningText("Speaker output can cause feedback. Use headphones, Bluetooth, or USB output when possible.")
            }
            
            if audioManager.selectedInputIsMissing {
                warningText("Selected input is missing. Reconnect it or choose another input.")
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .cornerRadius(20)
    }
    
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
                    .font(.system(size: 11, weight: .bold))
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
                Text("Select")
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
                    Circle()
                        .fill(audioManager.isRunning ? Color(red: 0.70, green: 0.16, blue: 0.18) : Color(red: 0.02, green: 0.58, blue: 0.60))
                        .frame(width: 132, height: 132)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                    
                    Image(systemName: "ear")
                        .font(.system(size: 55, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                Text(audioManager.isRunning ? "STOP LISTENING" : "LISTEN")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .tracking(1.5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(!audioManager.isRunning && audioManager.selectedInputIsMissing)
        .opacity((!audioManager.isRunning && audioManager.selectedInputIsMissing) ? 0.55 : 1.0)
    }
    
    private var statusArea: some View {
        VStack(spacing: 8) {
            Text(audioManager.isRunning ? "Listening is ON" : "Listening is OFF")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(audioManager.isRunning ? .green : .white.opacity(0.70))
            
            if let errorMessage = audioManager.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(minHeight: 58)
    }
    
    private func warningText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.orange)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
