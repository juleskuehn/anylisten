import SwiftUI

struct ContentView: View {
    @StateObject private var audioManager = AudioEngineManager()
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("AnyListen")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    
                    Text("Simple Microphone Audio Loopback")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)
                
                // Large toggle button
                Button(action: {
                    withAnimation {
                        audioManager.toggleListening()
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(audioManager.isRunning ? Color.red : Color.green)
                            .frame(width: 180, height: 180)
                            .shadow(radius: 8)
                        
                        VStack(spacing: 12) {
                            Image(systemName: audioManager.isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 40, weight: .bold))
                                .foregroundColor(.white)
                            
                            Text(audioManager.isRunning ? "STOP LISTENING" : "START LISTENING")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.vertical, 20)
                
                // Audio input & output status
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MICROPHONE INPUT")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            Text(audioManager.currentInputName)
                                .font(.body)
                                .fontWeight(.semibold)
                        }
                        Spacer()
                        Image(systemName: "mic.fill")
                            .foregroundColor(.blue)
                            .font(.title2)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AUDIO OUTPUT")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            Text(audioManager.currentOutputName)
                                .font(.body)
                                .fontWeight(.semibold)
                        }
                        Spacer()
                        
                        // Route selector button
                        AudioRoutePicker()
                            .frame(width: 44, height: 44)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                
                if let errorMessage = audioManager.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.bottom, 30)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
