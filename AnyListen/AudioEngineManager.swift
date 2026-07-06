import Foundation
import AVFoundation
import Combine

class AudioEngineManager: ObservableObject {
    private var audioEngine: AVAudioEngine?
    
    @Published var isRunning: Bool = false
    @Published var currentInputName: String = "None"
    @Published var currentOutputName: String = "None"
    @Published var errorMessage: String? = nil
    @Published var microphonePermissionStatus: AVAuthorizationStatus = .notDetermined
    
    private var cancellables = Set<AnyCancellable>()
    private var isAudioSessionConfigured = false
    
    init() {
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
    }
    
    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        
        do {
            try configureAudioSession()
            try setupAudioEngine()
            
            guard let audioEngine = audioEngine else {
                throw NSError(domain: "AnyListen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
            }
            
            try audioEngine.start()
            isRunning = true
            updateAudioRoutes()
        } catch {
            errorMessage = "Failed to start audio: \(error.localizedDescription)"
            isRunning = false
            teardownAudioEngine()
        }
    }
    
    func stop() {
        guard isRunning else { return }
        teardownAudioEngine()
        isRunning = false
        updateAudioRoutes()
    }
    
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        isAudioSessionConfigured = true
    }
    
    private func setupAudioEngine() throws {
        if audioEngine != nil {
            teardownAudioEngine()
        }
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AnyListen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid microphone input format"])
        }
        
        // Connect Input directly to Main Mixer
        engine.connect(inputNode, to: engine.mainMixerNode, format: inputFormat)
        
        self.audioEngine = engine
    }
    
    private func teardownAudioEngine() {
        audioEngine?.stop()
        audioEngine = nil
    }
    
    func updateAudioRoutes() {
        let session = AVAudioSession.sharedInstance()
        
        let inputs = session.currentRoute.inputs
        if let firstInput = inputs.first {
            currentInputName = firstInput.portName
        } else {
            currentInputName = "Built-in Microphone"
        }
        
        let outputs = session.currentRoute.outputs
        if let firstOutput = outputs.first {
            if firstOutput.portType == .bluetoothA2DP || firstOutput.portType == .bluetoothHFP || firstOutput.portType == .bluetoothLE {
                currentOutputName = "\(firstOutput.portName) (Bluetooth)"
            } else if firstOutput.portType.rawValue.contains("HearingAid") || firstOutput.portType.rawValue.contains("Hearing") {
                currentOutputName = "\(firstOutput.portName) (Hearing Aids)"
            } else {
                currentOutputName = firstOutput.portName
            }
        } else {
            currentOutputName = "iPhone Speaker"
        }
    }
    
    private func handleRouteChange(notification: Notification) {
        updateAudioRoutes()
        
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            if isRunning {
                restartEngine()
            }
        default:
            break
        }
    }
    
    private func handleEngineConfigurationChange() {
        if isRunning {
            restartEngine()
        }
    }
    
    private func handleMediaServicesReset() {
        isAudioSessionConfigured = false
        teardownAudioEngine()
        
        if isRunning {
            isRunning = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.start()
            }
        }
    }
    
    private func restartEngine() {
        let wasRunning = isRunning
        stop()
        if wasRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.start()
            }
        }
    }
}
