# ADR 0001: On-Device Parlo Turn Pipeline with Gemini REST for Ukrainian Meaning Helpers

- **Status**: Accepted
- **Date**: 2026-11-11

## Context

Mural's original iOS client (`Chuloo/mural`) delivers a calm, minimal conversational UI (`TalkView` with `MuralOrb`, word-linked following captions, `ThemesView`, and `WordsView` recall bars), but couples all voice and text interactions to OpenAI's cloud APIs (`gpt-live-1` over WebRTC and `gpt-6-luna` via `/v1/responses`), alongside hosted account/minute-billing machinery.

Meanwhile, Parlo (`iuriipleskach/Parlo`) proves an offline, zero-inference-cost on-device conversation loop for English (`en`) using iOS 26's `FoundationModels` (`@Generable RoleplayTurn`), deterministic `CorrectionGate` validation, a 4,096-token `TranscriptCondenser`, on-device `SFSpeechRecognizer`, and `AVSpeechSynthesizer`.

We want to combine Mural's minimal UI with Parlo's on-device conversation approach, scoped specifically to **English (`en`)** as the Target Language and **Ukrainian (`uk`)** as the Meaning Language.

Two platform constraints shape this architecture:
1. **Apple `FoundationModels` (`SystemLanguageModel.default`)** in iOS 26 supports English (`en-US`, `en-GB`), so spoken English conversation, inline corrections, and vocabulary assessment can run 100% on-device. However, `FoundationModels` does **not** support Ukrainian (`uk`) or Russian (`ru`).
2. **Apple's on-device `Translation` framework** produces low-quality Ukrainian translations for conversational idioms and contextual word lookups compared to frontier cloud models.

## Decision

1. **Hybrid Split by Modality**:
   - **Spoken English Conversation, Gated Corrections & Vocabulary Assessment (100% On-Device)**: Replace OpenAI WebRTC (`LiveTransport`) and cloud assessment with Parlo's on-device pipeline (`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` → `TranscriptCondenser` → `FoundationModels` `@Generable AFMRoleplayTurn` → `CorrectionGate` → `AVSpeechSynthesizer`, plus `@Generable AFMSessionAssessment` for `WordsView` recall bars). Voice practice requires zero API keys and zero internet connectivity.
   - **Ukrainian Meaning Subtitles & Word Lookups (`Meaning Helper` via Google Gemini REST)**: Route `MeaningController` (`TeachingPolicy.translation`) and `LookupView` (`TeachingPolicy.lookup`) through a lightweight unary `APIClient.respond` backed by Google Gemini REST (`gemini-2.5-flash:generateContent` with `thinkingBudget: 0`), authenticating with an optional user-supplied Gemini API key in Keychain.
2. **Preserve Provider & Budget Seams for Future Cloud Models**:
   - Keep `TokenBudget` and `RoleplayModel` protocol seams in `MuralCore` so that higher-context cloud conversation models (e.g., Gemini Live or OpenAI Realtime) can be plugged in later without rewriting `ConversationCoordinator` or `TalkView`.

## Consequences

- **Positive**:
  - Unlimited, zero-cost, offline English speaking practice with deterministic 4,096-token budgeting and high-precision (`CorrectionGate`) inline corrections.
  - High-quality Ukrainian (`uk`) meaning subtitles and contextual word lookups via Gemini Flash without paying for continuous cloud audio streaming.
  - Eliminates the ~200 MB `stasel/WebRTC` dependency, `services/api/`, `apps/android/`, hosted accounts, and 12 unused language modules.
- **Negative / Trade-offs**:
  - Turn-taking shifts from full-duplex WebRTC to half-duplex (`Silence Endpointing` + `Half-Duplex Handoff` pausing ASR while TTS speaks, with tap-on-Orb/Mic barge-in).
  - Ukrainian meaning subtitles and word lookups require connectivity and a Gemini API key (though English voice practice and vocabulary recall bars continue to work offline without one).
