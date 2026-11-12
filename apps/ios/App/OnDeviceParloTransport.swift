import AVFoundation
import Foundation
import MuralCore
import Speech
import os

/// Thread-safe audio capture state holder accessed by CoreAudio real-time tap.
private final class AudioState: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var _isCapturingAudio: Bool = false
    private var _latestRMS: Float = 0.0

    var isCapturingAudio: Bool {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _isCapturingAudio
        }
        set {
            os_unfair_lock_lock(&lock)
            _isCapturingAudio = newValue
            os_unfair_lock_unlock(&lock)
        }
    }

    var latestRMS: Float {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _latestRMS
        }
        set {
            os_unfair_lock_lock(&lock)
            _latestRMS = newValue
            os_unfair_lock_unlock(&lock)
        }
    }
}

/// On-device Parlo transport conforming to the interface expected by `ConversationCoordinator`.
///
/// Implements:
/// - 100% on-device speech recognition via `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`).
/// - Deterministic silence endpointing driven by ASR token stability (1.3s) and absolute turn timeout (10s).
/// - Single session-scoped `AVAudioEngine` across turns with safe tap removal and pause.
/// - Half-duplex handoff: ASR is paused while `AVSpeechSynthesizer` speaks.
/// - Tap-to-interrupt (barge-in): immediate TTS cutoff returning to Listening.
/// - 10 Hz EMA level metering for `MuralOrb`.
/// - Apple `FoundationModels` `@Generable AFMRoleplayTurn` with deterministic fallback.
/// - `CorrectionGate` validation for inline grammar and phrasing feedback.
@MainActor
public final class OnDeviceParloTransport: NSObject {
    public var onEvent: (([String: Any]) -> Void)?
    public var onLevels: ((Double, Double) -> Void)?
    public var onFailure: ((String) -> Void)?
    public var onHostedLease: ((Any) -> Void)?

    public private(set) var started = false
    public private(set) var isMuted = false

    private var sessionID = UUID()
    private var audioEngine: AVAudioEngine?
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var currentRecognitionTaskID: UUID?

    private let audioState = AudioState()

    private let synthesizer = AVSpeechSynthesizer()
    private var isSynthesizerSpeaking = false

    private let modelProvider: any RoleplayModelProviding
    private let promptBuilder = PromptBuilder()
    private let condenser = TranscriptCondenser()
    private let gate = CorrectionGate(languageID: "en")

    private var activeInstructions: String = ""
    private var currentDirective: String? = nil
    private var currentTheme: ConversationTheme?
    private var learnerState: LearnerState?
    private var interests: String = ""
    private var conversationHistory: ConversationHistory = .empty
    private var exchangeIndex = 0

    // Audio & silence tracking
    private var currentUtteranceText = ""
    private var lastASRTokenTime: Date?
    private var utteranceStartTime: Date?
    private var silenceCheckTimer: Task<Void, Never>?
    private var levelMeterTimer: Task<Void, Never>?

    private var currentInputRMS: Double = 0.0
    private var smoothedInputLevel: Double = 0.0
    private var smoothedOutputLevel: Double = 0.0

    private var isThinking = false
    private var isClosing = false

    public init(modelProvider: any RoleplayModelProviding = ModelProviderFactory.makeRoleplayModel()) {
        self.modelProvider = modelProvider
        super.init()
        self.synthesizer.delegate = self
    }

    deinit {
        silenceCheckTimer?.cancel()
        levelMeterTimer?.cancel()
    }

    // MARK: - Context Configuration

    public func setTheme(_ theme: ConversationTheme?) {
        self.currentTheme = theme
    }

    public func setLearnerContext(learner: LearnerState?, interests: String) {
        self.learnerState = learner
        self.interests = interests
    }

    // MARK: - Transport Lifecycle

    public func connect(
        api: APIClient,
        instructions: String,
        history: [[String: Any]] = [],
        hosted: Any? = nil,
        theme: ConversationTheme? = nil,
        learner: LearnerState? = nil,
        interests: String = ""
    ) async throws {
        disconnect()

        self.sessionID = UUID()
        self.activeInstructions = instructions
        self.currentTheme = theme
        self.learnerState = learner
        self.interests = interests
        self.conversationHistory = .empty
        self.exchangeIndex = 0
        self.isClosing = false
        self.isMuted = false
        self.started = false

        // Request microphone and speech recognition permissions
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            throw NSError(domain: "chat.mural.error", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission is required."])
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            throw NSError(domain: "chat.mural.error", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission is required."])
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw NSError(domain: "chat.mural.error", code: 3, userInfo: [NSLocalizedDescriptionKey: "English speech recognizer unavailable."])
        }
        self.speechRecognizer = recognizer

        // Configure session-scoped AVAudioSession
        try configureAudioSession()

        // Keep a single AVAudioEngine initialized for the session duration
        let engine = AVAudioEngine()
        self.audioEngine = engine
        engine.prepare()

        // Start level meter loop
        startLevelMeterLoop()

        // Emit synthetic mural.session.created & session.started
        onEvent?([
            "type": "mural.session.created",
            "session": ["id": sessionID.uuidString]
        ])

        self.started = true

        onEvent?([
            "type": "session.started",
            "session": ["id": sessionID.uuidString]
        ])

        // Begin listening for learner speech
        try startListening()
    }

    public func send(_ event: [String: Any]) -> Bool {
        guard let type = event["type"] as? String else { return false }

        switch type {
        case "session.instructions.append":
            if let content = event["content"] as? String {
                self.currentDirective = content

                if content.contains("The learner typed: ") {
                    if let range = content.range(of: "The learner typed: ") {
                        let typedText = String(content[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { @MainActor in
                            await self.generateAssistantTurn(learnerUtterance: typedText)
                        }
                    }
                } else if content.contains("Begin now in English") || content.contains("Begin this new conversation") || content.contains("Resume the conversation") {
                    Task { @MainActor in
                        await self.generateAssistantTurn(learnerUtterance: "")
                    }
                } else if content.contains("asks for help") {
                    Task { @MainActor in
                        await self.generateAssistantTurn(learnerUtterance: "Can you help me understand?")
                    }
                } else if content.contains("Check in with the learner") || content.contains("The learner has been quiet") {
                    Task { @MainActor in
                        await self.generateAssistantTurn(learnerUtterance: "")
                    }
                } else if content.contains("The learner selected a theme") {
                    if let matched = ConversationTheme.shared.first(where: { content.contains($0.situation) }) {
                        self.currentTheme = matched
                    } else if content.contains("Free conversation") {
                        self.currentTheme = nil
                    }
                }
            }
            return true

        case "session.thinking.append":
            return true

        case "session.commentary.append":
            if let content = event["content"] as? String {
                Task { @MainActor in
                    self.speak(text: content)
                }
            }
            return true

        case "session.close":
            close()
            return true

        default:
            return true
        }
    }

    public func mute(_ muted: Bool) {
        self.isMuted = muted
        if muted {
            if !currentUtteranceText.isEmpty {
                finalizeLearnerUtterance()
            }
            stopListening()
        } else {
            if !isSynthesizerSpeaking && !isThinking {
                try? startListening()
            }
        }
    }

    public func close() {
        self.isClosing = true
        self.isMuted = true
        silenceCheckTimer?.cancel()
        silenceCheckTimer = nil
        stopListening()
        synthesizer.stopSpeaking(at: .immediate)
        isSynthesizerSpeaking = false
    }

    public func disconnect() {
        close()
        levelMeterTimer?.cancel()
        levelMeterTimer = nil
        smoothedInputLevel = 0
        smoothedOutputLevel = 0
        onLevels?(0, 0)

        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {}
    }

    // MARK: - Audio Session & Level Metering

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startLevelMeterLoop() {
        levelMeterTimer?.cancel()
        levelMeterTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }

                // Controlled 10 Hz cadence reading atomically from audioState
                let latestRMS = Double(self.audioState.latestRMS)
                self.currentInputRMS = latestRMS

                // 10 Hz EMA smoothing
                if self.isMuted || self.isSynthesizerSpeaking || self.isThinking || !self.audioState.isCapturingAudio {
                    self.smoothedInputLevel = self.smoothedInputLevel * 0.35
                } else {
                    let target = min(1.0, latestRMS * 4.0)
                    self.smoothedInputLevel = self.smoothedInputLevel * 0.35 + target * 0.65
                }

                if self.isSynthesizerSpeaking {
                    let pulse = Double.random(in: 0.35...0.75)
                    self.smoothedOutputLevel = self.smoothedOutputLevel * 0.35 + pulse * 0.65
                } else {
                    self.smoothedOutputLevel = self.smoothedOutputLevel * 0.35
                }

                self.onLevels?(self.smoothedInputLevel, self.smoothedOutputLevel)
            }
        }
    }

    // MARK: - Listening & Silence Endpointing

    private func startListening() throws {
        guard !isSynthesizerSpeaking && !isThinking && !isMuted && !isClosing else { return }
        guard !audioState.isCapturingAudio else { return }

        // Clean up any lingering request or task before starting a new listening turn
        stopListening()

        let engine = self.audioEngine ?? AVAudioEngine()
        self.audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }

        if !engine.isRunning {
            try engine.start()
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.recognitionRequest = request
        self.currentUtteranceText = ""
        self.lastASRTokenTime = nil
        self.utteranceStartTime = nil

        // Set capturing flag before installing tap
        audioState.isCapturingAudio = true
        let taskID = UUID()
        self.currentRecognitionTaskID = taskID

        inputNode.removeTap(onBus: 0)
        let state = self.audioState
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            guard state.isCapturingAudio, let request else { return }
            request.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            if frames > 0 {
                var sum: Float = 0
                for i in 0..<frames {
                    let sample = channelData[i]
                    sum += sample * sample
                }
                state.latestRMS = sqrt(sum / Float(frames))
            }
        }

        guard let recognizer = speechRecognizer else { return }
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.currentRecognitionTaskID == taskID else { return }
                guard self.audioState.isCapturingAudio || !self.currentUtteranceText.isEmpty else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.handlePartialTranscription(text)
                }
            }
        }

        startSilenceCheckTimer()
    }

    private func stopListening() {
        silenceCheckTimer?.cancel()
        silenceCheckTimer = nil

        // 1. Set isCapturingAudio = false
        audioState.isCapturingAudio = false

        // 2. Remove input tap on bus 0
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            // 3. Pause or stop the engine input (do not rebuild the engine)
            if engine.isRunning {
                engine.pause()
            }
        }

        // 4. Only then call recognitionRequest?.endAudio()
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        currentRecognitionTaskID = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        currentInputRMS = 0
        audioState.latestRMS = 0
    }

    private func handlePartialTranscription(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let previousWords = currentUtteranceText.split(separator: " ").map(String.init)
        let newWords = trimmed.split(separator: " ").map(String.init)

        if utteranceStartTime == nil {
            utteranceStartTime = Date()
        }

        if newWords != previousWords {
            lastASRTokenTime = Date()
        }

        // Prevent duplicated text on ASR revisions:
        // Only emit clean deltas for newly appended words beyond what has already been emitted
        if newWords.count > previousWords.count {
            let newSuffix = newWords[previousWords.count...].joined(separator: " ")
            let delta = currentUtteranceText.isEmpty ? newSuffix : " " + newSuffix
            onEvent?([
                "type": "session.input_transcript.delta",
                "delta": delta,
                "start_ms": 0,
                "end_ms": 100
            ])
        }

        self.currentUtteranceText = trimmed
    }

    private func startSilenceCheckTimer() {
        silenceCheckTimer?.cancel()
        silenceCheckTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }

                // Silence endpointing is driven by:
                // 1. ASR partial text stability (no new tokens for 1.3s while !currentUtteranceText.isEmpty)
                // 2. Absolute turn timeout (10s while !currentUtteranceText.isEmpty) to guard against continuous ambient noise
                guard !self.currentUtteranceText.isEmpty else { continue }
                let now = Date()
                let tokenSilence = self.lastASRTokenTime.map { now.timeIntervalSince($0) >= 1.3 } ?? false
                let absoluteTimeout = self.utteranceStartTime.map { now.timeIntervalSince($0) >= 10.0 } ?? false

                if tokenSilence || absoluteTimeout {
                    self.finalizeLearnerUtterance()
                    break
                }
            }
        }
    }

    private func finalizeLearnerUtterance() {
        let utterance = currentUtteranceText
        stopListening()
        guard !utterance.isEmpty else { return }

        Task { @MainActor in
            await self.generateAssistantTurn(learnerUtterance: utterance)
        }
    }

    // MARK: - Model Inference & Turn Generation

    private func generateAssistantTurn(learnerUtterance: String) async {
        guard !isThinking && !isClosing else { return }
        isThinking = true

        // Forward theme, learner context, and user interests into bounded instructions
        let instructions = promptBuilder.instructions(
            theme: currentTheme,
            learner: learnerState,
            interests: interests,
            ephemeralDirective: currentDirective
        )
        self.currentDirective = nil // consume ephemeral directive

        // Condense history if needed
        let outcome = await condenser.condenseIfNeeded(
            instructions: instructions,
            history: conversationHistory,
            pendingUtterance: learnerUtterance,
            sessionID: sessionID
        )
        self.conversationHistory = outcome.history

        let prompt = RoleplayPrompt(
            instructions: instructions,
            history: outcome.history,
            learnerUtterance: learnerUtterance
        )

        do {
            let turn = try await modelProvider.generateTurn(for: prompt)

            // Gated correction evaluation
            var gatedCorrection: GatedCorrection? = nil
            if !learnerUtterance.isEmpty, let suggestion = turn.correction {
                let gated = gate.evaluate(suggestion, learnerUtterance: learnerUtterance)
                if gated.isShown {
                    gatedCorrection = gated
                    onEvent?([
                        "type": "session.correction",
                        "correction": gated
                    ])
                }
            }

            // Update conversation history
            let exchange = ConversationExchange(
                index: exchangeIndex,
                learner: learnerUtterance,
                partner: turn.reply
            )
            exchangeIndex += 1
            conversationHistory = conversationHistory.appending(exchange)

            self.isThinking = false

            // Speak assistant reply
            speak(text: turn.reply)

        } catch {
            self.isThinking = false
            onFailure?("Failed to generate response: \(error.localizedDescription)")
            if !isMuted && !isClosing {
                try? startListening()
            }
        }
    }

    // MARK: - Speech Synthesis (TTS) & Barge-In

    public func interrupt() {
        // Tap-to-interrupt (barge-in)
        if isSynthesizerSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            isSynthesizerSpeaking = false
            smoothedOutputLevel = 0
            if !isMuted && !isClosing {
                try? startListening()
            }
        }
    }

    private func speak(text: String) {
        guard !text.isEmpty && !isClosing else { return }

        stopListening()
        isSynthesizerSpeaking = true

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95

        // Emit output delta for following captions & meaning controller
        onEvent?([
            "type": "session.output_transcript.delta",
            "delta": text,
            "start_ms": 0,
            "end_ms": 1000
        ])

        synthesizer.speak(utterance)
    }
}

extension OnDeviceParloTransport: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSynthesizerSpeaking = false
            self.smoothedOutputLevel = 0
            if !self.isMuted && !self.isClosing {
                try? self.startListening()
            }
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSynthesizerSpeaking = false
            self.smoothedOutputLevel = 0
            if !self.isMuted && !self.isClosing {
                try? self.startListening()
            }
        }
    }
}
