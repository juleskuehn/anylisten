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
    private var playerNode: AVAudioPlayerNode?
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
        let wasRunning = isRunning
        if wasRunning {
            teardownAudioEngine()
            isRunning = false
        }
        
        selectedInputID = input.id
        selectedInputName = input.name
        selectedInputIsMissing = false
        UserDefaults.standard.set(input.id, forKey: selectedInputIDKey)
        UserDefaults.standard.set(input.name, forKey: selectedInputNameKey)
        errorMessage = nil
        
        do {
            try configureAudioSessionForCurrentSelection()
        } catch {
            errorMessage = "Could not select input: \(error.localizedDescription)"
        }
        updateAudioRoutes()
        
        // Auto-restart if we were listening before
        if wasRunning {
            start()
        }
    }
    
    func clearSelectedInput() {
        let wasRunning = isRunning
        if wasRunning {
            teardownAudioEngine()
            isRunning = false
        }
        
        selectedInputID = nil
        selectedInputName = nil
        selectedInputIsMissing = false
        UserDefaults.standard.removeObject(forKey: selectedInputIDKey)
        UserDefaults.standard.removeObject(forKey: selectedInputNameKey)
        errorMessage = nil
        
        do {
            try configureAudioSessionForCurrentSelection()
        } catch {
            errorMessage = "Could not reset input: \(error.localizedDescription)"
        }
        updateAudioRoutes()
        
        if wasRunning {
            start()
        }
    }
    
    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        
        do {
            ignoreRouteChangesUntil = Date().addingTimeInterval(2.0)
            try configureAudioSessionForCurrentSelection()
            
            // Verify the selected input is actually the active input
            let session = AVAudioSession.sharedInstance()
            let activeInput = session.currentRoute.inputs.first
            if let sid = selectedInputID, let activeInput = activeInput, activeInput.uid != sid {
                // Selected input is not the active one – try once more
                try applyPreferredInputIfNeeded(forceActive: true)
            }
            
            try setupAudioEngine()
            
            guard let audioEngine = audioEngine else {
                throw NSError(domain: "AnyListen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
            }
            
            try audioEngine.start()
            playerNode?.play()
            
            // Apply output override for built-in outputs only
            try applyOutputOverrideIfNeeded()
            
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
        }
        // Don't set a blanket errorMessage here — callers should set context-appropriate messages
    }
    
    /// Compute category options based on the selected input type.
    /// When the user selects a non-Bluetooth input (USB, built-in, etc.),
    /// we drop `.allowBluetooth` to keep AirPods in output-only A2DP mode.
    /// This prevents AirPods from hijacking the input route away from USB.
    private var sessionCategoryOptions: AVAudioSession.CategoryOptions {
        guard let sid = selectedInputID else {
            return [.allowBluetooth, .allowBluetoothA2DP]
        }
        // Check if the selected input is a Bluetooth device
        let session = AVAudioSession.sharedInstance()
        if let port = (session.availableInputs ?? []).first(where: { $0.uid == sid }) {
            let isBluetooth: Bool = {
                switch port.portType {
                case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return true
                default: return false
                }
            }()
            if !isBluetooth {
                // Non-Bluetooth input (USB, built-in, etc.):
                // Keep A2DP for output but drop HFP so AirPods stay output-only
                return [.allowBluetoothA2DP]
            }
        }
        return [.allowBluetooth, .allowBluetoothA2DP]
    }
    
    /// Full audio session configuration for the current input/output selection.
    /// Sets preferred input BEFORE activating the session so iOS routes correctly.
    private func configureAudioSessionForCurrentSelection() throws {
        let session = AVAudioSession.sharedInstance()
        isApplyingAudioSessionChange = true
        defer { isApplyingAudioSessionChange = false }
        
        // Deactivate first for a clean slate
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        
        try session.setCategory(.playAndRecord, mode: .default, options: sessionCategoryOptions)
        try session.setPreferredIOBufferDuration(0.005)
        
        // Set preferred input BEFORE activation — iOS is more likely to honor it
        try applyPreferredInputIfNeeded(forceActive: false)
        
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    private func applyOutputOverrideIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let shouldOverride = outputs.contains { output in
            output.portType == .builtInSpeaker || output.portType == .builtInReceiver
        }
        if shouldOverride {
            isApplyingAudioSessionChange = true
            defer { isApplyingAudioSessionChange = false }
            try session.overrideOutputAudioPort(.speaker)
        }
    }
    
    private func applyPreferredInputIfNeeded(forceActive: Bool) throws {
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
        
        // If forceActive, also set the session active again to apply the change
        if forceActive {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
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
        
        // Use tap-based loopback – more reliable than direct connection
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: inputFormat)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak player] buffer, _ in
            guard let player = player, player.isPlaying else { return }
            player.scheduleBuffer(buffer)
        }

        self.playerNode = player
        self.audioEngine = engine
    }
    
    private func teardownAudioEngine() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        playerNode = nil
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
            return "iPhone Speaker"
        case .builtInReceiver:
            return "iPhone Earpiece"
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
            if selectedInputIsMissing {
                if isRunning {
                    stopForSettingsChange()
                    errorMessage = "Selected input was disconnected."
                }
            }
        case .newDeviceAvailable:
            // Refresh inputs so the menu includes the new device
            updateAudioRoutes()
        case .categoryChange:
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
