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
///
/// 5. **Speaker route = blocked, period — "Connect headphones".**
///    Listening requires an external output (headphones / BT / USB /
///    AirPlay). Whenever iOS lands on the built-in speaker the Listen
///    button is disabled — whether the mic is built-in (feedback-prone
///    loopback) or external (speaker monitoring is not a supported
///    mode). Selecting the speaker in the route picker is NOT reported
///    as "X — missing": the headphones are still connected, just not
///    selected, and claiming otherwise is false. The "— missing" output
///    state is reserved for an OBSERVED device loss (a route change
///    with reason `.oldDeviceUnavailable` while routed to that device),
///    the only case where it's known true. (There is no
///    `availableOutputs` API, so `currentRoute.outputs` alone can't
///    distinguish "user chose speaker" from "device vanished" — the
///    route-change reason can.)
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

    // Remember the LAST external (non-built-in) input/output that was
    // actually routed, whether explicitly chosen by the user or
    // auto-upgraded by iOS. Kept across launches. When that device
    // disappears from `availableInputs` / `availableOutputs` we flag a
    // "missing" state in the UI instead of letting iOS silently
    // fall back to the iPhone mic/speaker — because the primary use
    // case is "external mic → external output" and a silent fallback
    // to internal hardware is exactly the wrong direction.
    private let lastExternalInputIDKey = "AnyListen.lastExternalInputID"
    private let lastExternalInputNameKey = "AnyListen.lastExternalInputName"
    private let lastExternalOutputIDKey = "AnyListen.lastExternalOutputID"
    private let lastExternalOutputNameKey = "AnyListen.lastExternalOutputName"
    private let autoListenEnabledKey = "AnyListen.autoListenEnabled"
    private let autoResumeEnabledKey = "AnyListen.autoResumeEnabled"
    private let monitorVolumeKey = "AnyListen.monitorVolume"

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

    /// Remembers whether the engine was running when an interruption
    /// (phone call, Siri, …) began, so we can auto-resume when it ends
    /// if the user has opted in. See `handleInterruption`.
    private var wasRunningBeforeInterruption: Bool = false

    // MARK: - Published state

    @Published var isRunning: Bool = false
    @Published var availableInputs: [AudioInputDevice] = []
    @Published var currentInputName: String = String(localized: "No input")
    @Published var currentOutputName: String = String(localized: "No output")
    @Published var selectedInputID: String? = nil
    @Published var selectedInputName: String? = nil
    @Published var selectedInputIsMissing: Bool = false
    @Published var errorMessage: String? = nil
    @Published var microphonePermissionStatus: AVAuthorizationStatus = .notDetermined

    /// Last observed non-built-in input port (whether chosen explicitly or
    /// auto-upgraded). Persisted across launches. Used in Automatic mode
    /// to keep showing the user that their preferred external mic is
    /// missing rather than silently displaying the iPhone mic.
    @Published var lastExternalInputID: String? = nil
    @Published var lastExternalInputName: String? = nil
    /// Same concept for output. We don't have an explicit "selected
    /// output" because iOS routes outputs through `AVRoutePickerView`,
    /// but iOS persists the user's AirPlay choice and will re-route to
    /// it when the device is back in range. We mirror that.
    @Published var lastExternalOutputID: String? = nil
    @Published var lastExternalOutputName: String? = nil
    /// True when we OBSERVED the previously routed external output being
    /// taken away (`.oldDeviceUnavailable` while routed to it) and iOS
    /// fell back to the speaker. Shown as "X — missing". Deliberately
    /// NOT set when the user picks the speaker in the route picker —
    /// that's `outputIsBlocked`, and the headphones aren't missing at
    /// all in that case. See `updateExternalOutputLossState`.
    @Published var outputIsMissing: Bool = false

    /// True when the current route output is the built-in speaker (and
    /// we're not in the observed-loss "missing" state). Listening is
    /// blocked here: the speaker card shows "Connect headphones" in
    /// orange and the Listen button is disabled with "Headphones
    /// required". This unifies the old iPhone-mic→speaker "dangerous
    /// loopback" guard with every other way of landing on the speaker.
    @Published var outputIsBlocked: Bool = false

    /// Set when a route change with reason `.oldDeviceUnavailable` moves
    /// us off a routed external output onto the speaker; cleared when
    /// any external output is routed again or the user overrides to the
    /// speaker. In-memory only: at launch a speaker route reads as
    /// blocked ("Connect headphones"), never "missing".
    private var externalOutputObservedLost = false

    /// User settings (persisted via Combine observers; see
    /// `setupSettingObservers`). See SettingsView.
    @Published var autoListenEnabled: Bool = false
    /// Auto-resume after an interruption (phone call, Siri, …) ends.
    /// Defaults to true so the "set and forget" appliance feel survives
    /// a phone call — the user was listening before, so they almost
    /// certainly want to be listening after.
    @Published var autoResumeEnabled: Bool = true
    @Published var monitorVolume: Float = 1.0

    private var hasManuallyStopped: Bool = false
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        selectedInputID = UserDefaults.standard.string(forKey: selectedInputIDKey)
        selectedInputName = UserDefaults.standard.string(forKey: selectedInputNameKey)
        lastExternalInputID = UserDefaults.standard.string(forKey: lastExternalInputIDKey)
        lastExternalInputName = UserDefaults.standard.string(forKey: lastExternalInputNameKey)
        lastExternalOutputID = UserDefaults.standard.string(forKey: lastExternalOutputIDKey)
        lastExternalOutputName = UserDefaults.standard.string(forKey: lastExternalOutputNameKey)
        autoListenEnabled = UserDefaults.standard.bool(forKey: autoListenEnabledKey)
        // bool(forKey:) returns false for a missing key, but we want
        // auto-resume ON by default — so use object(forKey:) and fall
        // back to true.
        autoResumeEnabled = (UserDefaults.standard.object(forKey: autoResumeEnabledKey) as? Bool) ?? true
        if let storedVolume = UserDefaults.standard.object(forKey: monitorVolumeKey) as? Float {
            monitorVolume = min(max(storedVolume, 0), 1)
        } else {
            monitorVolume = 1.0
        }
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

        setupSettingObservers()
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

    /// Persist the user settings and react to changes (auto-listen starts
    /// when toggled on if a usable route is already available). `dropFirst`
    /// skips the initial current-value emission Combine sends on subscribe,
    /// so loading persisted values in `init` does not trigger side effects.
    private func setupSettingObservers() {
        $autoResumeEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                UserDefaults.standard.set(value, forKey: self.autoResumeEnabledKey)
            }
            .store(in: &cancellables)

        $autoListenEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                UserDefaults.standard.set(value, forKey: self.autoListenEnabledKey)
                if value {
                    self.hasManuallyStopped = false
                }
                self.evaluateAutoListen()
            }
            .store(in: &cancellables)

        $monitorVolume
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                UserDefaults.standard.set(value, forKey: self.monitorVolumeKey)
                self.applyMonitorVolume()
            }
            .store(in: &cancellables)
    }

    // MARK: - User-facing commands

    func toggleListening() {
        if isRunning { stop() } else { beginListening() }
    }

    func beginListening() {
        hasManuallyStopped = false
        if microphonePermissionStatus == .authorized {
            start()
        } else {
            requestMicrophonePermission { [weak self] granted in
                if granted {
                    self?.start()
                } else {
                    self?.errorMessage = String(localized: "Microphone access is required to route audio.")
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
            configError = String(localized: "Could not select input: \(error.localizedDescription)")
        }
        updateAudioRoutes()
        lastRouteSignature = currentRouteSignature()

        if wasRunning {
            stopListening(withMessage: configError ?? String(localized: "Input changed. Tap LISTEN to resume."))
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
            configError = String(localized: "Could not reset input: \(error.localizedDescription)")
        }
        updateAudioRoutes()
        lastRouteSignature = currentRouteSignature()

        if wasRunning {
            stopListening(withMessage: configError ?? String(localized: "Input changed. Tap LISTEN to resume."))
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
            errorMessage = String(localized: "Failed to configure audio: \(error.localizedDescription)")
            updateAudioRoutes()
            return
        }

        rebuildEngineOnly()
        if isRunning { startEnumerationPolling() }
    }

    func stop() {
        guard isRunning else { return }
        hasManuallyStopped = true
        teardownEngine()
        isRunning = false
        errorMessage = nil
        updateAudioRoutes()
        // NB: session stays active on purpose — keeps USB enumerated and
        // preserves the user's route-picker output choice.
    }

    // MARK: - Monitor volume

    /// Applies `monitorVolume` to the live mixer. Zero added latency: the
    /// mixer already exists in the graph, so `outputVolume` is a scalar
    /// gain applied in the mixer's render — no limiter or effect node is
    /// inserted into the chain, preserving Live Listen latency parity.
    /// See docs/ROADMAP.md.
    private func applyMonitorVolume() {
        audioEngine?.mainMixerNode.outputVolume = monitorVolume
    }

    // MARK: - Auto-listen

    /// If auto-listen is on, start listening when a usable, non-feedback
    /// route is available. Stops are already handled by the existing
    /// route-change / missing-input policy, so this only needs to ADD
    /// starts when conditions become true.
    ///
    /// Honest limitation: this fires from route-change, foreground, and
    /// enumeration-poll callbacks. If the app is suspended in the
    /// background (no audio producing), iOS may not deliver a plug-in
    /// notification, so cold background auto-start is not guaranteed.
    func evaluateAutoListen() {
        guard autoListenEnabled, !isRunning else { return }
        guard !hasManuallyStopped else { return }
        guard microphonePermissionStatus == .authorized else { return }
        guard !selectedInputIsMissing, !outputIsMissing else { return }
        // Only auto-start when routing to an external (non-built-in)
        // output — headphones / Bluetooth / USB — never the iPhone speaker.
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let output = route.outputs.first,
              output.portType != .builtInSpeaker else { return }
        beginListening()
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
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "Failed to create audio engine.")])
            }
            try engine.start()
            isRunning = true
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Audio engine failed: \(error.localizedDescription)")
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
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Invalid audio input format.")])
        }
        engine.connect(inputNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = monitorVolume
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
                let missingName = selectedInputName ?? String(localized: "Selected input")
                throw NSError(domain: "AnyListen", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "\(missingName) is not connected. Reconnect it or choose a different input.")])
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

            // Auto-listen: a late-enumerating USB mic (or a route that
            // settled while we were backgrounded) can make the route
            // usable now.
            if self.autoListenEnabled, !self.isRunning {
                self.evaluateAutoListen()
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

        // -- INPUT ----------------------------------------------------------
        // Three branches:
        //  1. `selectedInputID` set (explicit): respect the explicit choice;
        //     flag missing if not in availableInputs.
        //  2. Automatic mode AND current route is non-built-in: remember
        //     this device so we can flag missing on disconnect later.
        //  3. Automatic mode AND current route fell back to built-in: if
        //     we previously had an external AND it's no longer in
        //     availableInputs, flag missing (this is the "USB mic was
        //     unplugged" path the user asked about).
        if let sid = selectedInputID {
            if let live = availableInputs.first(where: { $0.id == sid }) {
                selectedInputIsMissing = false
                currentInputName = live.name
            } else {
                selectedInputIsMissing = true
                currentInputName = Self.missingDisplayName(selectedInputName ?? String(localized: "Selected input"))
            }
        } else if let current = session.currentRoute.inputs.first {
            if current.portType != .builtInMic {
                saveLastExternalInput(id: current.uid, name: current.portName)
                selectedInputIsMissing = false
                currentInputName = current.portName
            } else {
                // iOS auto-fell-back to iPhone mic. Was our remembered
                // external a real device that's now unreachable?
                if let lastID = lastExternalInputID,
                   !inputs.contains(where: { $0.uid == lastID }) {
                    selectedInputIsMissing = true
                    currentInputName = Self.missingDisplayName(lastExternalInputName ?? String(localized: "External microphone"))
                } else {
                    selectedInputIsMissing = false
                    currentInputName = current.portName
                }
            }
        } else if let best = Self.bestAutomaticInput(from: inputs) {
            if best.portType != .builtInMic {
                saveLastExternalInput(id: best.uid, name: best.portName)
            }
            selectedInputIsMissing = false
            currentInputName = best.portName
        } else {
            currentInputName = String(localized: "No input available")
            selectedInputIsMissing = false
        }

        // -- OUTPUT ---------------------------------------------------------
        // Speaker route = blocked, period: listening requires an external
        // output (design note 5). The view turns that state into
        // "Connect headphones" + a disabled Listen button. The single
        // exception to the message is an OBSERVED loss of the previously
        // routed external output (see `updateExternalOutputLossState`),
        // which names the device: "X — missing".
        if let currentOutput = session.currentRoute.outputs.first {
            if currentOutput.portType == .builtInSpeaker {
                if externalOutputObservedLost, let lostName = lastExternalOutputName {
                    outputIsMissing = true
                    currentOutputName = Self.missingDisplayName(lostName)
                } else {
                    outputIsMissing = false
                    currentOutputName = Self.readableOutputName(currentOutput)
                }
                outputIsBlocked = !outputIsMissing
            } else {
                // An external output is routed: any observed loss is
                // resolved by definition.
                externalOutputObservedLost = false
                saveLastExternalOutput(id: currentOutput.uid, name: currentOutput.portName)
                outputIsMissing = false
                outputIsBlocked = false
                currentOutputName = Self.readableOutputName(currentOutput)
            }
        } else {
            currentOutputName = String(localized: "No output available")
            outputIsMissing = false
            outputIsBlocked = false
        }
    }

    /// Maintains `externalOutputObservedLost`, the memory that separates
    /// "the user's headphones vanished" from "the user chose the speaker".
    /// Both land on the same `currentRoute` (built-in speaker only), but
    /// the route-change REASON tells them apart: `.oldDeviceUnavailable`
    /// means iOS took the device away, `.override` means the user picked
    /// the speaker in the route picker. Only the former earns the
    /// "— missing" state. Called from `handleRouteChange` before
    /// `updateAudioRoutes`.
    private func updateExternalOutputLossState(notification: Notification) {
        let route = AVAudioSession.sharedInstance().currentRoute
        guard route.outputs.first?.portType == .builtInSpeaker else {
            externalOutputObservedLost = false
            return
        }
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
            .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
        switch reason {
        case .oldDeviceUnavailable:
            // Claim "missing" only if the PREVIOUS route actually had an
            // external output — i.e. we transitioned external → speaker
            // because that device went away. (An input-side loss while
            // already on the speaker must not flag the output.)
            let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                as? AVAudioSessionRouteDescription
            let lostExternalOutput = previous?.outputs.contains {
                $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
            } ?? false
            if lostExternalOutput {
                externalOutputObservedLost = true
            }
        case .override:
            // The user picked the speaker in the route picker: blocked
            // state, not missing — their headphones are still connected.
            externalOutputObservedLost = false
        default:
            break
        }
    }

    private func saveLastExternalInput(id: String, name: String) {
        lastExternalInputID = id
        lastExternalInputName = name
        UserDefaults.standard.set(id, forKey: lastExternalInputIDKey)
        UserDefaults.standard.set(name, forKey: lastExternalInputNameKey)
    }

    private func saveLastExternalOutput(id: String, name: String) {
        lastExternalOutputID = id
        lastExternalOutputName = name
        UserDefaults.standard.set(id, forKey: lastExternalOutputIDKey)
        UserDefaults.standard.set(name, forKey: lastExternalOutputNameKey)
    }

    /// Display name for a device that was previously routed but is no
    /// longer available, e.g. "Wireless ME RX — missing".
    private static func missingDisplayName(_ name: String) -> String {
        String(localized: "\(name) — missing")
    }

    /// Stop message when the device we depend on goes away mid-listen.
    /// Two complete sentences (not an interpolated "input"/"output" word)
    /// so each localizes as a whole phrase.
    private static func disconnectedMessage(selectedInputMissing: Bool) -> String {
        selectedInputMissing
            ? String(localized: "Selected input was disconnected.")
            : String(localized: "Selected output was disconnected.")
    }

    private static func readableInputType(_ portType: AVAudioSession.Port) -> String {
        switch portType {
        case .builtInMic: return String(localized: "Built-in")
        case .usbAudio: return String(localized: "USB")
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return String(localized: "Bluetooth")
        case .headsetMic: return String(localized: "Headset")
        case .lineIn: return String(localized: "Line In")
        default: return String(localized: "Input")
        }
    }

    private static func readableOutputName(_ output: AVAudioSessionPortDescription) -> String {
        switch output.portType {
        case .builtInSpeaker: return String(localized: "iPhone Speaker")
        case .builtInReceiver: return String(localized: "iPhone Earpiece")
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return String(localized: "\(output.portName) (Bluetooth)")
        case .headphones: return String(localized: "\(output.portName) (headphones)")
        case .usbAudio: return String(localized: "\(output.portName) (USB)")
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

        updateExternalOutputLossState(notification: notification)
        updateAudioRoutes()

        if isApplyingAudioSessionChange { return }

        if let until = silenceRouteChangesUntil, Date() < until {
            // Silenced — but a yanked selected input or output still stops us, and
            // an automatic input upgrade still earns an engine rebuild.
            let pinned = (try? applyPreferredInputIfNeeded()) ?? false
            if isRunning && (selectedInputIsMissing || outputIsMissing) {
                stopListening(withMessage: Self.disconnectedMessage(selectedInputMissing: selectedInputIsMissing))
                return
            }
            // Landing on the speaker also stops us, silenced or not —
            // speaker route is blocked, so we must never keep playing
            // into it (feedback screech risk if the user races the route
            // picker right after tapping LISTEN).
            if isRunning && outputIsBlocked {
                stopListening(withMessage: String(localized: "Audio route changed. Tap LISTEN to resume."))
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

        // Auto-listen: if enabled and a usable route is now available,
        // start. This is the response to the route change, so return
        // after starting to avoid the "signature changed → stop" logic
        // below treating the same change as a reason to stop.
        if autoListenEnabled, !isRunning {
            evaluateAutoListen()
            if isRunning { return }
        }

        guard isRunning else { return }

        if selectedInputIsMissing || outputIsMissing {
            stopListening(withMessage: Self.disconnectedMessage(selectedInputMissing: selectedInputIsMissing))
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
            stopListening(withMessage: String(localized: "Audio route changed. Tap LISTEN to resume."))
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
            // Remember whether we were live so we can resume after the
            // call / Siri / other-audio interruption ends.
            wasRunningBeforeInterruption = isRunning
            if isRunning {
                stopListening(withMessage: String(localized: "Audio interrupted."))
            }
        case .ended:
            sessionIsActive = false
            updateAudioRoutes()
            // Auto-resume: if the user was listening before the
            // interruption AND has opted in, spin the engine back up.
            // Guard against the blocked speaker route: if the headphones
            // came off during the call, the route is now the iPhone
            // speaker and resuming would screech. Same guard as
            // `evaluateAutoListen`. (`updateAudioRoutes` ran just above,
            // so these flags are fresh.)
            if autoResumeEnabled, wasRunningBeforeInterruption, !isRunning {
                if !outputIsBlocked, !outputIsMissing, !selectedInputIsMissing {
                    try? ensureSessionConfigured()
                    beginListening()
                }
            }
            wasRunningBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        teardownEngine()
        sessionIsActive = false
        sessionIsConfigured = false
        isRunning = false
        errorMessage = String(localized: "Audio system reset. Tap LISTEN when ready.")
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
        evaluateAutoListen()
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
