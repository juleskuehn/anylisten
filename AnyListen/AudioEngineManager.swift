import Foundation
import AVFoundation
import Combine

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let typeName: String
}

class AudioEngineManager: ObservableObject {
    private var audioEngine: AVAudioEngine?
    private let selectedInputIDKey = "AnyListen.selectedInputID"
    private let selectedInputNameKey = "AnyListen.selectedInputName"
    private var isApplyingAudioSessionChange = false
    private var ignoreRouteChangesUntil: Date? = nil
    
    @Published var isRunning: Bool = false
    @Published var availableInputs: [AudioInputDevice] = []
    @Published var currentInputName: String = "No input"
    @Published var currentOutputName: String = "No output"
    @Published var selectedInputID: String? = nil
    @Published var selectedInputName: String? = nil
    @Published var selectedInputIsMissing: Bool = false
    @Published var outputMayCauseFeedback: Bool = false
    @Published var errorMessage: String? = nil
    @Published var microphonePermissionStatus: AVAuthorizationStatus = .notDetermined
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        selectedInputID = UserDefaults.standard.string(forKey: selectedInputIDKey)
        selectedInputName = UserDefaults.standard.string(forKey: selectedInputNameKey)
        checkMicrophonePermission()
        setupNotifications()
        try? prepareAudioSessionForRouting()
        updateAudioRoutes()
    }
    
    func checkMicrophonePermission() {
        microphonePermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
    
    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.checkMicrophonePermission()
                completion(granted)
            }
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleRouteChange(notification: notification)
            }
            .store(in: &cancellables)
            
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMediaServicesReset()
            }
            .store(in: &cancellables)
            
        NotificationCenter.default.publisher(for: NSNotification.Name.AVAudioEngineConfigurationChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleEngineConfigurationChange()
            }
            .store(in: &cancellables)
    }
    
    func toggleListening() {
        if isRunning {
            stop()
        } else {
            beginListening()
        }
    }
    
    func beginListening() {
        if microphonePermissionStatus == .authorized {
            start()
        } else {
            requestMicrophonePermission { [weak self] granted in
                if granted {
                    self?.start()
                } else {
                    self?.errorMessage = "Microphone access is required to route audio."
                }
            }
        }
    }
    
    func selectInput(_ input: AudioInputDevice) {
        stopForSettingsChange()
        selectedInputID = input.id
        selectedInputName = input.name
        selectedInputIsMissing = false
        UserDefaults.standard.set(input.id, forKey: selectedInputIDKey)
        UserDefaults.standard.set(input.name, forKey: selectedInputNameKey)
        errorMessage = nil
        
        do {
            try prepareAudioSessionForRouting()
            try applyPreferredInputIfNeeded()
        } catch {
            errorMessage = "Could not select input: \(error.localizedDescription)"
        }
        updateAudioRoutes()
    }
    
    func clearSelectedInput() {
        stopForSettingsChange()
        selectedInputID = nil
        selectedInputName = nil
        selectedInputIsMissing = false
        UserDefaults.standard.removeObject(forKey: selectedInputIDKey)
        UserDefaults.standard.removeObject(forKey: selectedInputNameKey)
        errorMessage = nil
        
        do {
            try prepareAudioSessionForRouting()
            try AVAudioSession.sharedInstance().setPreferredInput(nil)
        } catch {
            errorMessage = "Could not reset input: \(error.localizedDescription)"
        }
        updateAudioRoutes()
    }
    
    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        
        do {
            // Starting the audio session itself can emit route/configuration notifications.
            // Ignore that short startup burst so Listen does not immediately stop itself.
            ignoreRouteChangesUntil = Date().addingTimeInterval(1.0)
            let shouldForceSpeakerOutput = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
            try configureAudioSession(forceSpeakerOutput: shouldForceSpeakerOutput)
            try setupAudioEngine()
            
            guard let audioEngine = audioEngine else {
                throw NSError(domain: "AnyListen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
            }
            
            try audioEngine.start()
            if shouldForceSpeakerOutput {
                try applyOutputOverride(forceSpeakerOutput: true)
            }
            isRunning = true
            updateAudioRoutes()
        } catch {
            errorMessage = "Failed to start listening: \(error.localizedDescription)"
            isRunning = false
            teardownAudioEngine()
            updateAudioRoutes()
        }
    }
    
    func stop() {
        guard isRunning else { return }
        teardownAudioEngine()
        isRunning = false
        updateAudioRoutes()
    }
    
    private func stopForSettingsChange() {
        if isRunning {
            teardownAudioEngine()
            isRunning = false
            errorMessage = "Listening stopped because audio settings changed."
        }
    }
    
    private func prepareAudioSessionForRouting() throws {
        let session = AVAudioSession.sharedInstance()
        isApplyingAudioSessionChange = true
        defer { isApplyingAudioSessionChange = false }
        
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    private func configureAudioSession(forceSpeakerOutput: Bool = false) throws {
        try prepareAudioSessionForRouting()
        try applyPreferredInputIfNeeded()
        try applyOutputOverride(forceSpeakerOutput: forceSpeakerOutput)
    }
    
    private func applyOutputOverride(forceSpeakerOutput: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        isApplyingAudioSessionChange = true
        defer { isApplyingAudioSessionChange = false }
        
        try session.overrideOutputAudioPort(forceSpeakerOutput ? .speaker : .none)
    }
    
    private func applyPreferredInputIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        
        guard let selectedInputID else {
            selectedInputIsMissing = false
            try session.setPreferredInput(nil)
            return
        }
        
        guard let selectedPort = inputs.first(where: { $0.uid == selectedInputID }) else {
            selectedInputIsMissing = true
            let missingName = selectedInputName ?? "Selected input"
            throw NSError(
                domain: "AnyListen",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(missingName) is not connected. Reconnect it or choose a different input."]
            )
        }
        
        selectedInputIsMissing = false
        try session.setPreferredInput(selectedPort)
    }
    
    private func setupAudioEngine() throws {
        if audioEngine != nil {
            teardownAudioEngine()
        }
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AnyListen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid audio input format"])
        }
        
        engine.connect(inputNode, to: engine.mainMixerNode, format: inputFormat)
        self.audioEngine = engine
    }
    
    private func teardownAudioEngine() {
        audioEngine?.stop()
        audioEngine = nil
    }
    
    func updateAudioRoutes() {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        availableInputs = inputs.map { input in
            AudioInputDevice(id: input.uid, name: input.portName, typeName: readableInputType(input.portType))
        }
        
        if let selectedInputID {
            if let selectedInput = availableInputs.first(where: { $0.id == selectedInputID }) {
                selectedInputIsMissing = false
                currentInputName = selectedInput.name
            } else {
                selectedInputIsMissing = true
                currentInputName = "\(selectedInputName ?? "Selected input") — missing"
            }
        } else if let firstInput = session.currentRoute.inputs.first {
            selectedInputIsMissing = false
            currentInputName = firstInput.portName
        } else if let firstAvailableInput = availableInputs.first {
            selectedInputIsMissing = false
            currentInputName = firstAvailableInput.name
        } else {
            selectedInputIsMissing = false
            currentInputName = "No input available"
        }
        
        if let firstOutput = session.currentRoute.outputs.first {
            currentOutputName = readableOutputName(firstOutput)
            outputMayCauseFeedback = firstOutput.portType == .builtInSpeaker
        } else {
            currentOutputName = "No output available"
            outputMayCauseFeedback = false
        }
    }
    
    private func readableInputType(_ portType: AVAudioSession.Port) -> String {
        switch portType {
        case .builtInMic: return "Built-in"
        case .usbAudio: return "USB"
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return "Bluetooth"
        case .headsetMic: return "Headset"
        case .lineIn: return "Line In"
        default: return "Input"
        }
    }
    
    private func readableOutputName(_ output: AVAudioSessionPortDescription) -> String {
        switch output.portType {
        case .builtInSpeaker:
            return "\(output.portName) (speaker)"
        case .builtInReceiver:
            return "\(output.portName) (receiver)"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return "\(output.portName) (Bluetooth)"
        case .headphones:
            return "\(output.portName) (headphones)"
        case .usbAudio:
            return "\(output.portName) (USB)"
        default:
            return output.portName
        }
    }
    
    private func handleRouteChange(notification: Notification) {
        updateAudioRoutes()
        
        guard !isApplyingAudioSessionChange else { return }
        
        if let ignoreRouteChangesUntil, Date() < ignoreRouteChangesUntil {
            return
        }
        self.ignoreRouteChangesUntil = nil
        
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .oldDeviceUnavailable:
            if isRunning {
                stopForSettingsChange()
            }
            if selectedInputIsMissing {
                errorMessage = "Selected input is missing. Reconnect it or choose another input."
            }
        case .newDeviceAvailable, .routeConfigurationChange, .override:
            if isRunning {
                stopForSettingsChange()
            }
        case .categoryChange:
            // Expected when AnyListen starts/configures its own audio session. Do not stop.
            break
        default:
            break
        }
    }
    
    private func handleEngineConfigurationChange() {
        // Engine configuration notifications can be emitted during normal startup.
        // Route-change notifications handle real input/output changes; avoid stopping
        // merely because the engine finished configuring itself.
        updateAudioRoutes()
    }
    
    private func handleMediaServicesReset() {
        teardownAudioEngine()
        isRunning = false
        errorMessage = "Audio system reset. Tap Listen when ready."
        updateAudioRoutes()
    }
}
