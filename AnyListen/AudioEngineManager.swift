import Foundation
import AVFoundation
import Combine
import UIKit

struct AudioInputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let typeName: String
}

/// Owns the audio session, the engine, and all published state.
///
/// Design notes (revised after on-device testing, round 3):
///
/// 1. **USB enumeration requires an ACTIVE session — and is asynchronous
///    by SECONDS, with no reliable notification when it completes.**
///    So: activate at launch when permission is already granted, then
///    POLL `availableInputs` briefly (0.5 s × ~12 ticks) re-pinning the
///    preferred input as devices appear. A persisted USB selection that
///    reads "— missing" at launch self-heals within a few seconds.
///
/// 2. **`.defaultToSpeaker`, never `overrideOutputAudioPort`.**
///    `.playAndRecord` without it defaults built-in output to the
///    earpiece. Session deactivation wipes output overrides, so we never
///    deactivate while the app is alive, and the native route picker's
///    choices (Speaker / AirPods / …) persist across stop/start.
///    Known trade-off: the picker no longer offers the earpiece.
///
/// 3. **Any route change while running → STOP, including in-app input
///    changes.** No auto-resume, no rebuild-under-a-running-engine.
///    Besides being the requested UX, it eliminates the freeze class
///    where teardown → session-reconfigure → engine-restart ran
///    synchronously while a USB route switch was in flight.
///
/// 4. **Direct input→mixer connection, no tap, no player node.**
///    The old tap-based loopback paid a 1024-frame capture buffer
///    (~21 ms @ 48 kHz) plus player scheduling jitter — audible next to
///    Live Listen. `engine.connect(inputNode → mainMixerNode)` costs
///    roughly one I/O buffer (~5 ms) and removes `removeTap`-while-
///    running (a freeze candidate) from the code entirely.
final class AudioEngineManager: ObservableObject {

    // MARK: - Tunables

    /// Suppress route-change *reactions* for this long after our own
    /// session edits. iOS fires a burst of notifications after
    /// setCategory/setActive/setPreferredInput; without this we'd stop
    /// ourselves in response to our own start sequence.
    private static let routeChangeSilenceWindowSeconds: TimeInterval = 2.5

    /// USB devices finish enumerating asynchronously, seconds after
    /// activation, without firing a usable notification. Poll this often…
    private static let enumerationPollIntervalSeconds: TimeInterval = 0.5
    /// …for this many ticks after activation/start (0.5 × 20 = 10 s).
    private static let enumerationPollMaxTicks = 20

    /// Audio I/O hint for monitoring latency. Honored on most devices
    /// for .playAndRecord; the direct connection means this ~5 ms buffer
    /// is essentially the entire app-added latency.
    private static let preferredIOBufferDurationSeconds: TimeInterval = 0.005

    // MARK: - Persistence

    private let selectedInputIDKey = "AnyListen.selectedInputID"
    private let selectedInputNameKey = "AnyListen.selectedInputName"

    // MARK: - Owned audio objects

    private var audioEngine: AVAudioEngine?

    // MARK: - Internal state flags

    /// True while we are synchronously editing the audio session.
    private var isApplyingAudioSessionChange = false
    private var silenceRouteChangesUntil: Date? = nil

    /// iOS does not expose whether OUR session is active — track it.
    private var sessionIsActive = false
    private var sessionIsConfigured = false

    /// Signature of the route we last knew about ("inputUID|outputUIDs").
    /// A change to this while running means the route we depend on
    /// actually changed → stop listening. Reason codes alone are too
    /// noisy to trust.
    private var lastRouteSignature = ""

    private var isRebuildingEngine = false
    private var enumerationPollTimer: Timer?

    // MARK: - Published state

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

    // MARK: - Init

    init() {
        selectedInputID = UserDefaults.standard.string(forKey: selectedInputIDKey)
        selectedInputName = UserDefaults.standard.string(forKey: selectedInputNameKey)
        checkMicrophonePermission()
        setupNotifications()

        if microphonePermissionStatus == .authorized {
            // Activate NOW so USB inputs begin enumerating at launch…
            try? ensureSessionConfigured()
            // …then poll, because enumeration completes asynchronously
            // seconds later without firing a notification.
            startEnumerationPolling()
        } else {
            // Can't activate a record session without permission (and we
            // don't want a launch-time prompt). Category priming at least
            // gets us the built-in list; full enumeration happens once
            // the user grants permission via LISTEN.
            primeSessionCategoryOnly()
        }

        _ = try? applyPreferredInputIfNeeded()
        lastRouteSignature = currentRouteSignature()
        updateAudioRoutes()
    }

    // MARK: - Permission

    func checkMicrophonePermission() {
        microphonePermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.checkMicrophonePermission()
                completion(granted)
            }
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in self?.handleRouteChange(notification: n) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleMediaServicesReset() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name.AVAudioEngineConfigurationChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleEngineConfigurationChange() }
            .store(in: &cancellables)

        // Phone calls / Siri / other apps grabbing audio. Without this,
        // an interruption kills our audio but leaves the button stuck ON.
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in self?.handleInterruption(notification: n) }
            .store(in: &cancellables)

        // Return from Settings (permission change) or background:
        // re-check permission, re-activate if needed, refresh routes.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleDidBecomeActive() }
            .store(in: &cancellables)
    }

    // MARK: - User-facing commands

    func toggleListening() {
        if isRunning { stop() } else { beginListening() }
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

    /// In-app input change. Policy: STOP if running (same as output
    /// changes). The engine is torn down BEFORE the session is touched —
    /// the old "reconfigure while the engine lives" path was the freeze.
    func selectInput(_ input: AudioInputDevice) {
        let wasRunning = isRunning
        if wasRunning {
            teardownEngine()
            isRunning = false
        }

        selectedInputID = input.id
        selectedInputName = input.name
        saveSelection(input.id, name: input.name)

        var configError: String? = nil
        do {
            try ensureSessionConfigured()
        } catch {
            configError = "Could not select input: \(error.localizedDescription)"
        }
        updateAudioRoutes()
        lastRouteSignature = currentRouteSignature()

        if wasRunning {
            stopListening(withMessage: configError ?? "Input changed. Tap LISTEN to resume.")
        } else {
            errorMessage = configError
        }
    }

    func clearSelectedInput() {
        let wasRunning = isRunning
        if wasRunning {
            teardownEngine()
            isRunning = false
        }

        selectedInputID = nil
        selectedInputName = nil
        clearSelection()

        var configError: String? = nil
        do {
            try ensureSessionConfigured()
        } catch {
            configError = "Could not reset input: \(error.localizedDescription)"
        }
        updateAudioRoutes()
        lastRouteSignature = currentRouteSignature()

        if wasRunning {
            stopListening(withMessage: configError ?? "Input changed. Tap LISTEN to resume.")
        } else {
            errorMessage = configError
        }
    }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil

        do {
            try ensureSessionConfigured()
        } catch {
            errorMessage = "Failed to configure audio: \(error.localizedDescription)"
            updateAudioRoutes()
            return
        }

        rebuildEngineOnly()
        if isRunning { startEnumerationPolling() }
    }

    func stop() {
        guard isRunning else { return }
        teardownEngine()
        isRunning = false
        errorMessage = nil
        updateAudioRoutes()
        // NB: session stays active on purpose — keeps USB enumerated and
        // preserves the user's route-picker output choice.
    }

    // MARK: - Engine lifecycle (no session touch!)

    /// Teardown + rebuild + start the AVAudioEngine against the CURRENT
    /// session. Never deactivates or reconfigures the session, so output
    /// overrides (route picker choices) survive.
    private func rebuildEngineOnly() {
        guard !isRebuildingEngine else { return }
        isRebuildingEngine = true
        defer { isRebuildingEngine = false }

        teardownEngine()
        do {
            try setupAudioEngine()
            guard let engine = audioEngine else {
                throw NSError(domain: "AnyListen", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine."])
            }
            try engine.start()
            isRunning = true
            errorMessage = nil
        } catch {
            errorMessage = "Audio engine failed: \(error.localizedDescription)"
            teardownEngine()
            isRunning = false
        }
        lastRouteSignature = currentRouteSignature()
        updateAudioRoutes()
    }

    private func teardownEngine() {
        // Direct connection ⇒ no tap to remove. stop() releases the input.
        audioEngine?.stop()
        audioEngine = nil
    }

    /// Low-latency monitoring path: input node connected DIRECTLY to the
    /// main mixer. No tap buffer (the old 1024-frame tap cost ~21 ms of
    /// capture-side latency) and no AVAudioPlayerNode scheduling jitter.
    /// The mixer handles any sample-rate conversion to the output route.
    private func setupAudioEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(domain: "AnyListen", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid audio input format."])
        }
        engine.connect(inputNode, to: engine.mainMixerNode, format: format)
        self.audioEngine = engine
    }

    // MARK: - Session configuration (used sparingly)

    /// Category set + preferred input + activate — but each step only
    /// when actually needed. We avoid deactivate/reactivate cycles
    /// because deactivation wipes output overrides (route picker picks).
    private func ensureSessionConfigured() throws {
        let session = AVAudioSession.sharedInstance()
        isApplyingAudioSessionChange = true
        defer { isApplyingAudioSessionChange = false }
        silenceRouteChangesTemporarily()

        let desiredOptions = sessionCategoryOptions
        let categoryStale = !sessionIsConfigured
            || session.category != .playAndRecord
            || session.categoryOptions != desiredOptions

        if categoryStale {
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: desiredOptions)
                try session.setPreferredIOBufferDuration(Self.preferredIOBufferDurationSeconds)
            } catch {
                // Some category transitions refuse to apply while active.
                // Fall back to a deactivate → set → (reactivate below).
                try? session.setActive(false)
                sessionIsActive = false
                try session.setCategory(.playAndRecord, mode: .default, options: desiredOptions)
                try session.setPreferredIOBufferDuration(Self.preferredIOBufferDurationSeconds)
            }
            sessionIsConfigured = true
        }

        // Activate BEFORE applying the preferred input — critical
        // ordering. applyPreferredInputIfNeeded THROWS when the persisted
        // selection hasn't enumerated yet; if activation came after it,
        // that throw would skip activation entirely, and since USB
        // enumeration REQUIRES an active session, the device would stay
        // "— missing" forever. (This was the cold-launch USB bug: the
        // output picker only "fixed" it because presenting
        // AVRoutePickerView makes the SYSTEM activate the session.)
        if !sessionIsActive {
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionIsActive = true
        }

        try applyPreferredInputIfNeeded()
    }

    /// Launch path for when we do NOT have mic permission yet: set the
    /// category so at least the built-in inputs enumerate, but don't
    /// activate (activation would prompt or fail).
    private func primeSessionCategoryOnly() {
        let session = AVAudioSession.sharedInstance()
        isApplyingAudioSessionChange = true
        defer { isApplyingAudioSessionChange = false }
        try? session.setCategory(.playAndRecord, mode: .default, options: sessionCategoryOptions)
        try? session.setPreferredIOBufferDuration(Self.preferredIOBufferDurationSeconds)
        sessionIsConfigured = true
    }

    /// Category options.
    ///
    /// Always: `.defaultToSpeaker` (built-in output defaults to the loud
    /// speaker, not the earpiece) and `.allowBluetoothA2DP` (AirPods /
    /// BT speakers stay available as OUTPUT).
    ///
    /// `.allowBluetooth` (HFP input) is opt-in ONLY: added when the user
    /// has explicitly selected a Bluetooth port as their input. This
    /// keeps iOS from silently promoting a BT mic over USB in Automatic
    /// mode, and keeps BT mics out of the picker unless chosen.
    private var sessionCategoryOptions: AVAudioSession.CategoryOptions {
        if let sid = selectedInputID,
           let port = AVAudioSession.sharedInstance().availableInputs?.first(where: { $0.uid == sid }),
           Self.isBluetoothPort(port.portType) {
            return [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        }
        return [.allowBluetoothA2DP, .defaultToSpeaker]
    }

    private static func isBluetoothPort(_ portType: AVAudioSession.Port) -> Bool {
        switch portType {
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return true
        default: return false
        }
    }

    /// Automatic-mode input ranking. External mics beat the built-in mic;
    /// Bluetooth ranks last (it normally isn't even enumerated because
    /// HFP is off unless explicitly selected). This is what makes
    /// "Automatic" mean "use the plugged-in USB mic".
    private static func automaticInputRank(_ portType: AVAudioSession.Port) -> Int {
        switch portType {
        case .usbAudio, .headsetMic, .lineIn: return 0
        case .builtInMic: return 1
        default: return 2
        }
    }

    private static func bestAutomaticInput(from inputs: [AVAudioSessionPortDescription]) -> AVAudioSessionPortDescription? {
        inputs.min { automaticInputRank($0.portType) < automaticInputRank($1.portType) }
    }

    /// Explicit mode: pin the selected port; throw (and flag missing) if
    /// it disappeared. Automatic mode: pin the best-ranked available input.
    /// Never activates the session — activation is centralized in
    /// `ensureSessionConfigured`.
    ///
    /// Returns `true` only when the call actually MOVED the input
    /// preference (pinned port differs from the route input that was
    /// current on entry). Callers use this to (a) rebuild the engine if
    /// it's running — the input format may have changed — and (b) extend
    /// the silence window so the notification tail of our own
    /// `setPreferredInput` can't read as an external route change.
    @discardableResult
    private func applyPreferredInputIfNeeded() throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let currentInputUID = session.currentRoute.inputs.first?.uid

        let target: AVAudioSessionPortDescription?
        if let sid = selectedInputID {
            guard let selectedPort = inputs.first(where: { $0.uid == sid }) else {
                selectedInputIsMissing = true
                let missingName = selectedInputName ?? "Selected input"
                throw NSError(domain: "AnyListen", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "\(missingName) is not connected. Reconnect it or choose a different input."])
            }
            selectedInputIsMissing = false
            target = selectedPort
        } else {
            selectedInputIsMissing = false
            target = Self.bestAutomaticInput(from: inputs)
        }

        // Already routed where we want — no-op, and crucially no
        // redundant setPreferredInput (which would fire a notification
        // we'd have to suppress).
        guard let target, target.uid != currentInputUID else { return false }
        try session.setPreferredInput(target)
        return true
    }

    // MARK: - Enumeration polling

    /// USB devices finish enumerating asynchronously — seconds after
    /// session activation — without firing a usable notification. Poll
    /// briefly after activation/start: refresh the picker, and when a
    /// better input appears, pin it (self-heals "— missing" at launch
    /// and upgrades Automatic to USB without the user touching anything).
    private func startEnumerationPolling() {
        enumerationPollTimer?.invalidate()
        var ticks = 0
        enumerationPollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.enumerationPollIntervalSeconds,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            ticks += 1

            // Defensive: if activation hasn't stuck (launch-time setActive
            // can race early app-lifecycle timing), retry it here.
            if !self.sessionIsActive,
               self.microphonePermissionStatus == .authorized {
                try? self.ensureSessionConfigured()
            }

            let pinned = (try? self.applyPreferredInputIfNeeded()) ?? false
            self.updateAudioRoutes()

            if pinned {
                // Absorb the notification tail of our own setPreferredInput,
                // and if live, rebuild so the engine picks up the new
                // input's format.
                self.silenceRouteChangesTemporarily()
                if self.isRunning { self.rebuildEngineOnly() }
            }

            if ticks >= Self.enumerationPollMaxTicks {
                timer.invalidate()
                self.enumerationPollTimer = nil
            }
        }
    }

    // MARK: - Route signature

    private func currentRouteSignature() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputUID = route.inputs.first?.uid ?? "none"
        let outputUIDs = route.outputs.map { $0.uid }.joined(separator: ",")
        return inputUID + "|" + outputUIDs
    }

    // MARK: - Route queries and display strings

    func updateAudioRoutes() {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        availableInputs = inputs.map {
            AudioInputDevice(id: $0.uid, name: $0.portName, typeName: Self.readableInputType($0.portType))
        }

        if let sid = selectedInputID {
            if let live = availableInputs.first(where: { $0.id == sid }) {
                selectedInputIsMissing = false
                currentInputName = live.name
            } else {
                selectedInputIsMissing = true
                currentInputName = "\(selectedInputName ?? "Selected input") — missing"
            }
        } else if let current = session.currentRoute.inputs.first {
            selectedInputIsMissing = false
            currentInputName = current.portName
        } else if let best = Self.bestAutomaticInput(from: inputs) {
            currentInputName = best.portName
        } else {
            currentInputName = "No input available"
        }

        if let firstOutput = session.currentRoute.outputs.first {
            currentOutputName = Self.readableOutputName(firstOutput)
            outputMayCauseFeedback = firstOutput.portType == .builtInSpeaker
        } else {
            currentOutputName = "No output available"
            outputMayCauseFeedback = false
        }
    }

    private static func readableInputType(_ portType: AVAudioSession.Port) -> String {
        switch portType {
        case .builtInMic: return "Built-in"
        case .usbAudio: return "USB"
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return "Bluetooth"
        case .headsetMic: return "Headset"
        case .lineIn: return "Line In"
        default: return "Input"
        }
    }

    private static func readableOutputName(_ output: AVAudioSessionPortDescription) -> String {
        switch output.portType {
        case .builtInSpeaker: return "iPhone Speaker"
        case .builtInReceiver: return "iPhone Earpiece"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return "\(output.portName) (Bluetooth)"
        case .headphones: return "\(output.portName) (headphones)"
        case .usbAudio: return "\(output.portName) (USB)"
        default: return output.portName
        }
    }

    // MARK: - Notification handlers

    /// Any REAL change to the route we depend on while running → stop
    /// with a message. "Real" is decided by comparing route signatures,
    /// not by trusting reason codes. Even while silenced we refresh UI
    /// and absorb the new signature — and we always honor a physically
    /// removed selected input, silenced or not.
    private func handleRouteChange(notification: Notification) {
        let previousSignature = lastRouteSignature
        let newSignature = currentRouteSignature()
        lastRouteSignature = newSignature

        updateAudioRoutes()

        if isApplyingAudioSessionChange { return }

        if let until = silenceRouteChangesUntil, Date() < until {
            // Silenced — but a yanked selected input still stops us, and
            // an automatic input upgrade still earns an engine rebuild.
            let pinned = (try? applyPreferredInputIfNeeded()) ?? false
            if isRunning && selectedInputIsMissing {
                stopListening(withMessage: "Selected input was disconnected.")
                return
            }
            if isRunning && pinned {
                silenceRouteChangesTemporarily()  // absorb tail of our own setPreferredInput
                rebuildEngineOnly()
            }
            return
        }
        silenceRouteChangesUntil = nil

        // Re-pick automatic best / flag missing explicit selection.
        let pinned = (try? applyPreferredInputIfNeeded()) ?? false
        updateAudioRoutes()

        guard isRunning else { return }

        if selectedInputIsMissing {
            stopListening(withMessage: "Selected input was disconnected.")
            return
        }

        if pinned {
            // We moved the input ourselves (automatic upgrade, e.g. USB
            // finished enumerating). Rebuild the engine for the new
            // input format — this is NOT an external route change.
            silenceRouteChangesTemporarily()
            rebuildEngineOnly()
            return
        }

        if newSignature != previousSignature {
            stopListening(withMessage: "Audio route changed. Tap LISTEN to resume.")
        }
    }

    private func handleEngineConfigurationChange() {
        // Fires spuriously during startup (which is silenced), but also
        // on genuine format shifts. Rebuilding the engine only — never
        // the session — is safe.
        guard isRunning, !isRebuildingEngine else {
            if !isRunning { updateAudioRoutes() }
            return
        }
        if let until = silenceRouteChangesUntil, Date() < until { return }
        // Silence before rebuilding so any notification tail from our
        // own engine restart can't re-enter this handler in a loop.
        silenceRouteChangesTemporarily()
        rebuildEngineOnly()
    }

    private func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            sessionIsActive = false
            if isRunning {
                stopListening(withMessage: "Audio interrupted. Tap LISTEN when ready.")
            }
        case .ended:
            // Never auto-resume; next LISTEN reactivates.
            sessionIsActive = false
            updateAudioRoutes()
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        teardownEngine()
        sessionIsActive = false
        sessionIsConfigured = false
        isRunning = false
        errorMessage = "Audio system reset. Tap LISTEN when ready."
        updateAudioRoutes()
    }

    private func handleDidBecomeActive() {
        checkMicrophonePermission()
        if microphonePermissionStatus == .authorized {
            if !sessionIsActive {
                try? ensureSessionConfigured()
                _ = try? applyPreferredInputIfNeeded()
            }
            startEnumerationPolling()
        }
        updateAudioRoutes()
    }

    // MARK: - Stopping

    private func stopListening(withMessage message: String) {
        teardownEngine()
        isRunning = false
        errorMessage = message
        updateAudioRoutes()
    }

    // MARK: - Persistence helpers

    private func saveSelection(_ id: String, name: String) {
        UserDefaults.standard.set(id, forKey: selectedInputIDKey)
        UserDefaults.standard.set(name, forKey: selectedInputNameKey)
    }

    private func clearSelection() {
        UserDefaults.standard.removeObject(forKey: selectedInputIDKey)
        UserDefaults.standard.removeObject(forKey: selectedInputNameKey)
    }

    // MARK: - Debouncing

    private func silenceRouteChangesTemporarily() {
        silenceRouteChangesUntil = Date().addingTimeInterval(Self.routeChangeSilenceWindowSeconds)
    }
}
