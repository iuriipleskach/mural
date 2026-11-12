# Specification: On-Device Mural (Parlo Engine + English / Ukrainian Edition)

> Canonical specification produced by `/wayfinder` map **[On-Device Mural (Parlo Engine + English/Ukrainian)](https://github.com/iuriipleskach/mural/issues/1)**.
> Domain vocabulary follows [`GLOSSARY.md`](../GLOSSARY.md) and [`ADR 0001`](./adr/0001-on-device-parlo-engine-with-gemini-ukrainian-helpers.md).

---

## 1. Product Scope & Architecture Overview

Mural (On-Device English + Ukrainian Edition) pairs Mural's minimal iOS SwiftUI interface (`TalkView` animated `MuralOrb`, word-linked following captions, `ThemesView`, and `WordsView` 3-bar `Recall Bars`) with Parlo's on-device inference pipeline:

- **Target Language**: Fixed to **English (`en`, `en-US`)**. All spoken conversation, inline corrections (`CorrectionGate`), and vocabulary/capability assessments (`On-Device Assessment`) execute 100% on-device using Apple `FoundationModels`, `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`), and `AVSpeechSynthesizer`.
- **Meaning Language**: Fixed to **Ukrainian (`uk`, `"Ukrainian"`)**. Live translated meaning subtitles (`MeaningController`) and tap-to-lookup word explanations (`LookupView`) are served by the cloud **`Meaning Helper`** via unary Google Gemini REST (`gemini-2.5-flash:generateContent`).
- **Removed / Out of Scope**:
  - All 12 non-English target languages (`nb`, `es`, `fr`, `de`, `it`, `pt`, `zh`, `sr`, `el`, `tl`, `nl`, `ru`) and 15 non-Ukrainian meaning languages.
  - `stasel/WebRTC` dependency, OpenAI Realtime WebRTC (`LiveTransport`), and OpenAI `/v1/responses` SSE streaming.
  - Hosted accounts (`ManagedAccountView`, `HostedAccess`), StoreKit billing / Mural minutes, and `services/api/`.
  - `apps/android/` client.
  - Web-search grounding (`CurrentTopicView` / `"The world today"` theme / `ask_mural` delegation).
  - Parlo's `wav2vec2` GOP pronunciation scoring and Parlo's StoreKit paywall.

---

## 2. Module & Build Packaging ([Ticket #7](https://github.com/iuriipleskach/mural/issues/7))

- **`MuralCore` (`apps/ios/Core/` & `apps/ios/Tests/`)**:
  - Retains `Models.swift`, `LearningEngine.swift`, `CaptionFollowing.swift`, `CaptionWords.swift`, `ConversationActivity.swift`, `ConversationPace.swift`, `Themes.swift` (23 offline themes, removing `today`), `TeachingPolicy.swift` (English + Ukrainian only), and `Languages/English.swift` (`LanguageRegistry.all = [.english]`, `MeaningLanguages.all = ["Ukrainian"]`).
  - Absorbs Parlo's pure-Swift domain & deterministic engine components:
    - `RoleplayTurn` & `GatedCorrection` (`CorrectionSuggestion`, `CorrectionCategory`, `GateOutcome`).
    - `CorrectionGate` (deterministic 8-rule validator configured for `.english`: `emptyCorrection`, `originalNotInUtterance`, `noChange`, `nonTargetCharset`, `foreignContent`, `lengthImplausible`, `categoryMismatch`).
    - `TokenBudget` (`afmDefault`: 4,096 window, 3,200 `callBudget`, 640 `responseReserve`) & `TokenEstimator` (UTF-8 byte count / 3).
    - `TranscriptCondenser` & `DeterministicSummarizer` (retaining last 3 verbatim exchanges + condensed summary of older exchanges).
    - `PromptBuilder` (bounded ~150-token English system prompt + `Ephemeral Turn Directive` slot + provider/budget abstraction for future cloud models).
  - Tested via `swift test --package-path apps/ios`.
- **`Mural` App Target (`apps/ios/App/` & `apps/ios/UITests/`)**:
  - Removes `stasel/WebRTC` from `scripts/generate_project.py` and `apps/ios/Mural.xcodeproj`.
  - Adds `FoundationModelProvider.swift` (`@Generable AFMRoleplayTurn` and `@Generable AFMSessionAssessment` with deterministic fallback when `SystemLanguageModel.default` is unavailable on Simulator).
  - Replaces WebRTC `LiveTransport.swift` with `OnDeviceParloTransport.swift` implementing the transport interface consumed by `ConversationCoordinator`.

---

## 3. On-Device Turn Loop & `TalkView` UX ([Ticket #2](https://github.com/iuriipleskach/mural/issues/2), [Ticket #4](https://github.com/iuriipleskach/mural/issues/4))

### 3.1 Session Audio Lifecycle & Half-Duplex Handoff
- `AVAudioSession.sharedInstance()` is configured once on session start (`setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])`, `setActive(true)`) and deactivated only when the conversation ends (`disconnect()`).
- **Half-Duplex Handoff**:
  1. **Listening Phase**: `AVAudioEngine` input tap on bus 0 feeds audio buffers to `SFSpeechAudioBufferRecognitionRequest` (`SFSpeechRecognizer(locale: Locale(identifier: "en-US"))`, `requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true`).
  2. **Silence Endpointing**: As the learner speaks, partial transcripts emit `session.input_transcript.delta` so `YOU ...` updates live on `TalkView`. When ~1.2–1.5 seconds of sustained audio RMS silence + stable ASR partial text is reached (or when the user taps **Mute** mid-utterance), ASR finalizes the utterance and transitions to **Thinking**.
  3. **Thinking Phase**: ASR capture is paused. `PromptBuilder` + `TranscriptCondenser` assemble the bounded prompt (verified by `TokenBudget.afmDefault.fits`), and `FoundationModelProvider` generates `@Generable AFMRoleplayTurn`.
  4. **Speaking Phase**: `AVSpeechSynthesizer` speaks `RoleplayTurn.reply` using an English `AVSpeechSynthesisVoice`. ASR remains paused while TTS speaks so speaker output is never self-transcribed. When `speechSynthesizer(_:didFinish:)` fires, ASR automatically re-arms (unless muted).
  5. **Tap-to-Interrupt (Barge-In)**: Tapping `MuralOrb` or toggling the center Mic button while TTS is speaking immediately calls `synthesizer.stopSpeaking(at: .immediate)` and transitions to **Listening**.

### 3.2 `MuralOrb` Energy & Caption Synchronization
- **Listening**: 10 Hz EMA-smoothed RMS `inputLevel` (`0.0...1.0`) computed on the `AVAudioEngine` input tap drives `MuralOrb`.
- **Thinking**: `inputLevel = 0.0`, `outputLevel = 0.0` (calm breathing orb).
- **Speaking**: `AVSpeechSynthesizerDelegate` (`didStart`, `willSpeakRangeOfSpeechString`, `didFinish`, `didCancel`) drives `session.output_transcript.delta` (and triggers `MeaningController` when Ukrainian subtitles are visible) while emitting a smooth 10 Hz modulated `outputLevel` envelope (`0.35...0.85` pulsed on word boundaries, dropping to `0.0` on finish/cancel).

### 3.3 Inactivity Check-In & Session Timer
- Preserves Mural's 3-strike 15-second silence `checkIn` loop: after 15s of silence while listening, `ConversationCoordinator` sets the `Ephemeral Turn Directive` to `TeachingPolicy.checkIn(language: .english)` and triggers a short check-in turn; after 3 unanswered check-ins (~45s) or when `timeLimitMinutes` expires, the session ends cleanly.

---

## 4. Gated Corrections & On-Device Vocabulary Assessment ([Ticket #5](https://github.com/iuriipleskach/mural/issues/5))

### 4.1 Streamlined `@Generable` Turn Schema
```swift
@Generable
struct AFMRoleplayTurn: Sendable, Equatable {
    @Guide(description: "Your natural, warm spoken English reply (1 to 3 short sentences, ending with at most one question). Do not lecture about grammar in the spoken reply.")
    var reply: String

    @Guide(description: "Exact substring from the learner's latest utterance that contained a clear English grammar, vocabulary, or register error, or empty string if none.")
    var correctionOriginal: String?

    @Guide(description: "Corrected English phrasing for correctionOriginal, or empty string if no correction is needed.")
    var correctionCorrected: String?

    @Guide(description: "Category of the correction: grammar, vocab, or register, or empty string if none.")
    var correctionCategory: String?
}
```
- `naturalness` and `naturalnessNote` are omitted to save output tokens and latency and keep `TalkView` minimal.
- Every model turn passes through `CorrectionGate.evaluate(turn:learnerUtterance:language:.english)`.

### 4.2 Presenting Corrections on `TalkView` and `TranscriptView`
- `AVSpeechSynthesizer` speaks **only** `reply`.
- When `CorrectionGate` returns `.shown(let correction)`:
  - `Passage` (role `.user`) stores `correction: GatedCorrection?`.
  - On `TalkView`, a single quiet line (`→ "\(correction.corrected)"`) renders directly underneath the learner's `YOU ...` line.
  - In `TranscriptView` / `SessionHistoryView`, the correction renders beneath the learner passage.
  - If the learner edits a misheard `.user` passage in `EditableTranscriptView`, `passage.correction` is cleared and `reassess(_:)` is triggered.

### 4.3 `On-Device Assessment` for `WordsView` & `Recall Bars`
- Periodic (every 6 user turns) and post-session (`FinalAssessmentQueue`) assessments run **on-device** via `@Generable AFMSessionAssessment` on Apple `FoundationModels`, extracting:
  - `suggestedLevel` (`0...5`),
  - `nextGoal` (short English teaching focus),
  - `capabilities` (`[String]`), and
  - Up to 6 practiced English citation lemmas (`words: [AFMWordEvidence]`), automatically marking words involved in a `CorrectionGate` hit as `neededHelp` and unaided accurate usage as `usedWell`.
- Results feed into `LearningEngine.validate` and `LearningEngine.project` so `WordsView`, `RecallBars`, and `FlashcardsView` work 100% offline.
- When a Gemini API key is configured in `CredentialStore`, newly extracted words without a Ukrainian gloss request a concise Ukrainian sense via `Meaning Helper` in the background.

---

## 5. Bounded Prompting, Themes & Secondary Helpers ([Ticket #6](https://github.com/iuriipleskach/mural/issues/6))

### 5.1 Bounded ~150-Token Prompt & `Ephemeral Turn Directive`
- `PromptBuilder` constructs the session instructions within ~150 tokens:
  1. **Role & Register**: Warm English conversation partner (`Mural`), speaking only natural English (1–3 sentences, at most one question per turn).
  2. **Theme Situation**: Active `ConversationTheme.situation` (from the 23 curated themes in `Themes.swift` + `English.swift` overrides, or `"Just talk"`).
  3. **Learner Context**: Up to 5 due vocabulary lemmas (`learner.words`) + learner interests (`prefix(200)`).
  4. **Ephemeral Turn Directive**: Single replaceable slot for `greeting`, `checkIn`, `help()`, `redirect`, or `ConversationPace` guidance (never appended as an growing log).
- Before every call to `LanguageModelSession`, `TranscriptCondenser` condenses exchanges older than the 3 most recent turns into a deterministic summary, guaranteeing `TokenBudget.afmDefault.fits(...) == true`.
- **Cloud Extensibility**: `PromptBuilder` and `ConversationEngine` accept a configurable `TokenBudget` and `RoleplayModel` protocol so larger-context cloud models (e.g. Gemini or OpenAI) can be added in the future.

### 5.2 Secondary Helper Features
- **Type instead (`TypedReplyView`)**: Submits the typed English text directly into the on-device turn pipeline (`AsrEngine.typed` → `AFMRoleplayTurn` → `CorrectionGate` → TTS speaks `reply`).
- **A little help (`coordinator.help()`)**: Sets the `Ephemeral Turn Directive` to `TeachingPolicy.help(language: .english)` and triggers an on-device turn that restates the last idea more simply and speaks it via TTS.
- **The world today (`CurrentTopicView` / `ask_mural`)**: Removed so all 23 English themes + `"Just talk"` operate 100% offline.

---

## 6. Gemini `Meaning Helper`, Onboarding & Settings ([Ticket #3](https://github.com/iuriipleskach/mural/issues/3), [Ticket #7](https://github.com/iuriipleskach/mural/issues/7))

### 6.1 Gemini REST `APIClient.respond`
- `APIClient` is simplified to a single unary Gemini REST call (`POST https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent` with `x-goog-api-key` header and `thinkingConfig: { thinkingBudget: 0 }`).
- Serves `MeaningController` (`TeachingPolicy.translation` → Ukrainian meaning subtitles on `TalkView`), `LookupView` (`TeachingPolicy.lookup` → Ukrainian word meaning & grammar explanation when tapping any word in `targetPassage`), and background Ukrainian glosses for new `WordsView` items.

### 6.2 Zero-Step Launch & Streamlined `SettingsView`
- **Launch**: `OnboardingView` and `AIConsentView` are removed. Defaults are fixed to `learningLanguageID = "en"` and `meaningLanguage = "Ukrainian"`. The app opens straight into `TalkView` (`"Hello"`).
- **Missing Gemini Key Prompt**: Starting an English voice conversation never requires an API key. If the user toggles **Meaning** on or taps a word for **Lookup** when `CredentialStore.hasKey == false`, a lightweight prompt directs them to enter their Gemini API key in Settings.
- **`SettingsView` Sections**:
  1. **Ukrainian Meaning (`Meaning Helper`)**: Toggle for Ukrainian subtitles (`meaningVisible`) + Gemini API key input stored in Keychain (`CredentialStore`).
  2. **Practice Preferences**: Learner interests text field (≤ 200 chars) + session duration limit picker (`timeLimitMinutes`).
  3. **Local Data**: JSON learning backup export/import (`LearningBackupView`) + delete conversation history / reset learning data.
