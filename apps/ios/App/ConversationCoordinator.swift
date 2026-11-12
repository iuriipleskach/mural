import Foundation
import Observation
import NaturalLanguage
import AVFoundation
import UIKit
import MuralCore

@MainActor @Observable final class ConversationCoordinator {
    let store: LearningStore
    private(set) var state: ConnectionState = .idle
    private(set) var session: SessionRecord?
    var selectedTheme: ConversationTheme?
    var targetCaptionFollowing = CaptionFollowing()
    var meaningCaptionFollowing = CaptionFollowing()
    private(set) var inputLevel = 0.0
    private(set) var outputLevel = 0.0
    private(set) var isMuted = false
    private let meanings: MeaningController
    private let finalAssessments: FinalAssessmentQueue
    var meaning: String { meanings.text }
    var translating: Bool { meanings.isLoading }
    var meaningError: String? { meanings.error }
    var canRetryMeaning: Bool { meanings.canRetry }
    private(set) var working = false
    var error: String?
    var typedReplyError: String?
    var notice: String?
    var showSettings = false
    var requestAdvancedFocus = false
    private let api: APIClient
    private let transport = OnDeviceParloTransport()
    private var connectionTask: Task<Void, Never>?
    private var assessmentTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var activity = ConversationActivity(now: 0)
    private var conversationPace = ConversationPace()
    private(set) var inactivitySeconds: Int?
    private var activityNow: Double { ProcessInfo.processInfo.systemUptime }
    func noteTypingActivity() { if state == .active { activity.typing(now: activityNow); inactivitySeconds = nil } }
    private var pendingCommands: [String: Date] = [:]
    private var lastAssessmentKey = ""
    private var startingWithHistory = false
    private var languageGeneration = UUID()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var finalizationTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var resetDeadline: Date?

    init(store: LearningStore) {
        self.store = store
        let api = APIClient(); self.api = api
        finalAssessments = FinalAssessmentQueue { snapshot, passage in
            return try await Self.assess(snapshot: snapshot, passage: passage)
        }
        meanings = MeaningController(streaming: { request, onText in
            guard CredentialStore.hasKey else { throw ProviderFailure.missingKey }
            guard let language = LanguageRegistry.module(for: request.learningLanguageID) else { throw ArchiveError.unsupportedLanguage }
            let result = try await api.respond(instructions: TeachingPolicy.translation(language: language, meaningLanguage: request.meaningLanguage), input: request.translationInput, onText: onText)
            return MeaningResult(text: result.text, inputTokens: result.usage.input, outputTokens: result.usage.output)
        })
        meanings.onResult = { [weak self] request, result in
            guard let self, self.session?.id == request.sessionID else { return }
            self.session?.translations[request.cacheKey] = result.text
            self.session?.inputTokens += result.inputTokens; self.session?.outputTokens += result.outputTokens
            self.save()
        }
        finalAssessments.onResult = { [weak self] result in
            guard let self, let updated = result.applying(to: self.store.sessions.first(where: { $0.id == result.sessionID })) else { return }
            self.store.save(updated)
            if self.session?.id == updated.id { self.session = updated }
        }
        store.onSessionInvalidation = { [weak self] id in self?.finalAssessments.cancel(id) }
        transport.onEvent = { [weak self] in self?.handle($0) }
        transport.onLevels = { [weak self] input, output in
            guard let self else { return }
            self.inputLevel = input; self.outputLevel = output
            if self.state == .active {
                if input > 0.03 { self.activity.inputActive(now: self.activityNow) }
                if output > 0.03 { self.activity.assistantActive(now: self.activityNow) }
            }
        }
        transport.onFailure = { [weak self] in self?.fail($0) }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.end(reason: "Audio interrupted") }
        })
    }

    var isRunning: Bool { state == .active || state == .connecting || state == .closing }
    var language: LanguageModule { store.language }
    var assistantPassage: Passage? { session?.passages.last(where: { $0.speaker == .assistant }) }
    var userPassage: Passage? { session?.passages.last(where: { $0.speaker == .user }) }
    var caption: String { assistantPassage?.text ?? language.greeting }
    var status: String {
        if state == .active, let seconds = inactivitySeconds { return "Ending in \(seconds)s\nReply to continue" }
        return switch state {
        case .idle: "Ready when you are"
        case .connecting: "Getting comfortable…"
        case .active: outputLevel > 0.02 ? "Mural is speaking" : inputLevel > 0.02 ? "I’m listening" : "Take your time"
        case .closing: "Saving our conversation…"
        case .ended: "Until next time"
        case .failed: "Let’s try again"
        }
    }

    func start() {
        guard !isRunning, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else { return }
        releaseBackgroundWork()
        cancelReset(); meanings.reset()
        error = nil; notice = nil; lastAssessmentKey = ""
        pendingCommands = [:]
        state = .connecting; isMuted = false
        var record = SessionRecord(languageID: language.id, themeID: selectedTheme?.id, title: selectedTheme?.title)
        session = record; store.save(record)
        let generation = record.id
        let learner = store.learner
        let instructions = TeachingPolicy.voice(language: language, learner: learner, theme: selectedTheme, interests: store.preferences.interests, meaningLanguage: store.preferences.meaningLanguage)
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.session?.id == generation, self.state == .connecting else { return }
                try await self.transport.connect(api: self.api, instructions: instructions)
            }
            catch is CancellationError { return }
            catch {
                guard self.session?.id == generation, self.state == .connecting || self.state == .active else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    func interrupt() {
        transport.interrupt()
    }

    func selectLanguage(_ id: String) {
        guard !isRunning, id != language.id, LanguageRegistry.module(for: id) != nil else { return }
        cancelReset(); languageGeneration = UUID()
        connectionTask?.cancel(); closeTask?.cancel(); durationTask?.cancel()
        meanings.reset(); assessmentTask?.cancel(); saveTask?.cancel(); saveTask = nil
        session = nil; selectedTheme = nil
        working = false; notice = nil; error = nil
        lastAssessmentKey = ""; pendingCommands = [:]
        inputLevel = 0; outputLevel = 0; state = .idle; isMuted = false
        store.selectLanguage(id)
    }

    func selectMeaningLanguage(_ value: String) {
        guard MeaningLanguages.all.contains(value) else { return }
        meanings.reset()
        store.updatePreferences { $0.meaningLanguage = value }
        scheduleTranslation()
    }

    func chooseTheme(_ theme: ConversationTheme?) {
        if !isRunning, session != nil { resetConversation() }
        selectedTheme = theme
        if state == .active || state == .connecting {
            session?.themeID = theme?.id; session?.title = theme?.title ?? language.defaultTitle
            startingWithHistory = false
            if state == .active { append("instructions", TeachingPolicy.theme(theme, language: language)) }
            save()
        }
    }

    func toggleMute() {
        guard state == .active else { return }
        isMuted.toggle(); transport.mute(isMuted)
    }

    func deleteLearningData() {
        guard !isRunning else { return }
        meanings.reset(); assessmentTask?.cancel(); saveTask?.cancel(); saveTask = nil
        resetConversation()
        store.deleteAll()
    }

    func toggleMeaning() {
        store.updatePreferences { $0.meaningVisible.toggle() }
        if store.preferences.meaningVisible { scheduleTranslation() }
        else { meanings.reset() }
    }

    func help() {
        guard state == .active else { return }
        activity.learnerEngaged(now: activityNow); inactivitySeconds = nil
        conversationPace.askForHelp(after: userPassage)
        append("instructions", conversationPace.instruction)
        append("instructions", TeachingPolicy.help(language: language))
        notice = "Mural will make that a little simpler."
    }

    func end(reason: String = "Ended by you") {
        guard state == .active || state == .connecting else { return }
        let wasConnecting = state == .connecting
        state = .closing; isMuted = true
        connectionTask?.cancel(); assessmentTask?.cancel()
        durationTask?.cancel(); working = false
        session?.endReason = reason
        if wasConnecting { finish(final: false); return }
        transport.close()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self?.state == .closing else { return }
            self?.finish(final: false)
        }
    }

    func background() {
        guard isRunning else { return }
        if transport.started && (state == .active || state == .closing) { save(); return }
        beginBackgroundWork()
        end(reason: "App moved to background")
    }

    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish Mural conversation") { [weak self] in
            Task { @MainActor in self?.finish(final: false); self?.releaseBackgroundWork() }
        }
    }

    private func releaseBackgroundWork() {
        finalizationTask?.cancel(); finalizationTask = nil
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }

    private func finish(final: Bool) {
        guard isRunning else { return }
        if UIApplication.shared.applicationState == .background { beginBackgroundWork() }
        closeTask?.cancel(); durationTask?.cancel(); connectionTask?.cancel()
        assessmentTask?.cancel(); saveTask?.cancel(); saveTask = nil
        transport.disconnect(); pendingCommands = [:]; working = false
        session?.endedAt = .now; session?.usageFinal = final
        save(); state = .ended
        if let session { finalAssessments.submit(session) }
        scheduleTranslation()
        scheduleReset()
        if backgroundTask != .invalid {
            let owner = backgroundTask, id = session?.id
            finalizationTask?.cancel()
            finalizationTask = Task { [weak self] in
                let deadline = ContinuousClock.now + .seconds(15)
                while let self, ContinuousClock.now < deadline,
                      (id.map { self.finalAssessments.isPending($0) } ?? false) || self.meanings.isLoading {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                guard !Task.isCancelled, let self, self.backgroundTask == owner else { return }
                self.releaseBackgroundWork()
            }
        }
    }

    private func fail(_ message: String) {
        error = message; session?.endReason = "Connection failed"
        finish(final: false); cancelReset(); state = .failed
    }

    private func save() { if let session { store.save(session) } }
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }; self?.save(); self?.saveTask = nil
        }
    }

    @discardableResult private func append(_ kind: String, _ text: String) -> Bool {
        guard state == .active else { return false }
        let id = UUID().uuidString
        let accepted = transport.send(["type": "session.\(kind).append", "event_id": id, "content": String(text.prefix(1000))])
        if accepted { pendingCommands[id] = .now }
        return accepted
    }

    private func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String, session != nil else { return }
        switch type {
        case "mural.session.created":
            session?.providerID = (event["session"] as? [String: Any])?["id"] as? String
            session?.voiceSeconds = 15; save()
        case "session.started":
            guard state == .connecting else { return }
            state = .active; activity = ConversationActivity(now: activityNow); conversationPace = ConversationPace(); inactivitySeconds = nil
            session?.providerID = (event["session"] as? [String: Any])?["id"] as? String
            append("instructions", TeachingPolicy.greeting(language: language, theme: selectedTheme, continuing: startingWithHistory))
            startDurationChecks(); save()
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard state == .active || state == .closing, let delta = event["delta"] as? String,
                  let start = event["start_ms"] as? Int, let end = event["end_ms"] as? Int, start >= 0, end >= start else { return }
            let speaker: Speaker = type == "session.input_transcript.delta" ? .user : .assistant
            let fragment = Fragment(id: event["event_id"] as? String ?? UUID().uuidString, speaker: speaker, text: delta,
                                    startMS: start, endMS: end, meaningVisible: store.preferences.meaningVisible)
            session?.append(fragment); scheduleSave()
            if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if speaker == .user { activity.learnerEngaged(now: activityNow); inactivitySeconds = nil }
                else { activity.assistantActive(now: activityNow) }
            }
            if speaker == .assistant { scheduleTranslation() }
            else if state == .active { scheduleAssessment() }
        case "session.correction":
            if let correction = event["correction"] as? GatedCorrection {
                if let lastUserIndex = session?.passages.lastIndex(where: { $0.speaker == .user }) {
                    session?.passages[lastUserIndex].correction = correction
                    scheduleSave()
                }
            }
        case "session.closed":
            finish(final: true)
        case "error":
            let details = event["error"] as? [String: Any]
            if let msg = details?["message"] as? String { notice = msg }
        default:
            break
        }
    }

    private func startDurationChecks() {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.state == .active, let session = self.session else { return }
                let requestedDeadline = session.startedAt.addingTimeInterval(Double(self.store.preferences.sessionMinutes * 60))
                if Date() >= requestedDeadline {
                    self.notice = "You’ve reached your conversation time limit."; self.end(reason: "Time limit"); return
                }
                self.inactivitySeconds = nil
                switch self.activity.tick(now: self.activityNow, muted: self.isMuted, busy: self.working) {
                case .checkIn: self.append("instructions", TeachingPolicy.checkIn(language: self.language))
                case .warning(let seconds): self.inactivitySeconds = seconds
                case .end:
                    self.notice = "Mural ended this quiet session to avoid running up usage."; self.end(reason: "Inactivity"); return
                case .wait: break
                }
            }
        }
    }

    private func scheduleTranslation() {
        guard store.preferences.meaningVisible, let session, let passage = assistantPassage else { return }
        let request = MeaningRequest(sessionID: session.id, passage: passage, learningLanguageID: session.languageID, meaningLanguage: store.preferences.meaningLanguage)
        meanings.update(request, cached: session.translations[request.cacheKey], conversationEnded: state == .ended)
    }

    func retryMeaning() { scheduleTranslation(); meanings.retry() }

    func resetConversation() {
        guard !isRunning else { return }
        cancelReset(); meanings.reset(); saveTask?.cancel(); saveTask = nil
        languageGeneration = UUID()
        session = nil; selectedTheme = nil
        notice = nil; error = nil; working = false; isMuted = false
        inputLevel = 0; outputLevel = 0; state = .idle
    }

    private func cancelReset() { resetTask?.cancel(); resetTask = nil; resetDeadline = nil }
    private func scheduleReset() {
        cancelReset()
        guard let sessionID = session?.id else { return }
        resetDeadline = Date().addingTimeInterval(15)
        resetTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.state == .ended, self.session?.id == sessionID else { return }
            self.resetConversation()
        }
    }

    func resume() {
        if state == .ended, let resetDeadline, Date() >= resetDeadline { resetConversation() }
    }

    private static func assess(snapshot: SessionRecord, passage: Passage) async throws -> FinalAssessmentResult {
        let provider = FoundationModelProvider()
        let proposed = try await provider.assessSession(passage: passage, context: snapshot.themeID ?? "free", languageID: snapshot.languageID)
        return FinalAssessmentResult(sessionID: snapshot.id, languageID: snapshot.languageID, assessment: proposed, inputTokens: 0, outputTokens: 0, searchCalls: 0)
    }

    private func scheduleAssessment() {
        assessmentTask?.cancel()
        assessmentTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard let self, let snapshot = self.session,
                      let p = snapshot.passages.last(where: { $0.speaker == .user }),
                      p.text.count >= 3,
                      p.revisionKey != self.lastAssessmentKey,
                      self.state == .active else { return }
                let userPassages = snapshot.passages.filter { $0.speaker == .user }
                guard userPassages.count > 0, userPassages.count % 6 == 0 else { return }
                let result = try await Self.assess(snapshot: snapshot, passage: p)
                guard !Task.isCancelled, self.state == .active, self.session?.id == snapshot.id,
                      let current = self.session else { return }
                guard let validated = LearningEngine.validate(result.assessment, session: current) else { return }
                self.session?.assessments.removeAll { $0.passageID == p.id }
                self.session?.assessments.append(validated)
                self.lastAssessmentKey = p.revisionKey
                self.save()
            } catch {}
        }
    }

    @discardableResult func sendTyped(_ text: String) async -> Bool {
        typedReplyError = nil
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working else { return false }
        guard state == .active, !clean.isEmpty, var draft = session else {
            typedReplyError = "Start a conversation before sending your reply."
            return false
        }
        let sessionID = draft.id
        let offset = draft.nextTypedVoiceOffsetMS
        let fragment = Fragment(speaker: .user, text: String(clean.prefix(2000)), startMS: offset, endMS: offset + 1,
                                meaningVisible: store.preferences.meaningVisible, typed: true)
        draft.append(fragment)
        activity.learnerEngaged(now: activityNow); inactivitySeconds = nil
        working = true
        defer { if session?.id == sessionID { working = false } }
        session?.append(fragment)
        activity.learnerEngaged(now: activityNow); inactivitySeconds = nil
        save()
        _ = append("instructions", "The learner typed: \(clean)")
        scheduleAssessment()
        return true
    }

    func lookup(word: String, sentence: String) async throws -> String {
        guard CredentialStore.hasKey else { throw ProviderFailure.missingKey }
        let generation = languageGeneration, sessionID = session?.id
        let result = try await api.respond(instructions: TeachingPolicy.lookup(language: language, meaningLanguage: store.preferences.meaningLanguage), input: "Selected: \(word)\nSentence: \(sentence)", purpose: "lookup")
        guard generation == languageGeneration else { throw CancellationError() }
        if session?.id == sessionID {
            session?.inputTokens += result.usage.input; session?.outputTokens += result.usage.output
            scheduleSave()
        }
        return result.text
    }
}
