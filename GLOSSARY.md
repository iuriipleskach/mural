# Mural (On-Device English + Ukrainian Edition)

An iOS conversational language-learning app that pairs Mural's minimal voice UI with Parlo's on-device inference pipeline for spoken English practice, supported by Gemini-powered Ukrainian meaning subtitles and word lookups.

## Language

**Target Language**:
The language the learner practices speaking and reading in conversation, fixed to English (`en`).
_Avoid_: Learning language, foreign language, practice language

**Meaning Language**:
The reference language used for translated subtitles and word lookups, fixed to Ukrainian (`uk`).
_Avoid_: Subtitle language, support language, native language, translation language

**On-Device Turn Loop**:
The offline capture-to-speech cycle executing entirely on the iPhone: on-device ASR (`SpeechTranscriber` / `SFSpeechRecognizer`) → `TranscriptCondenser` (4,096-token budget) → Apple `FoundationModels` (`@Generable RoleplayTurn`) → `CorrectionGate` → on-device TTS (`AVSpeechSynthesizer`).
_Avoid_: Cloud voice session, realtime WebRTC call, live audio stream

**RoleplayTurn**:
A structured model turn emitted by Apple `FoundationModels` containing the spoken `reply` and an optional `correction` (`original`, `corrected`, `category`).
_Avoid_: Raw completion, unstructured chat message, naturalness meter

**CorrectionGate**:
The deterministic validation filter that suppresses any model-suggested correction that fails target-language, diff, length, or category checks before it can reach the learner.
_Avoid_: AI self-check, prompt filter

**On-Device Assessment**:
The structured `@Generable` Apple `FoundationModels` pass that extracts practiced English citation lemmas, outcomes (`usedWell` / `neededHelp`, informed by `CorrectionGate` hits), and capability observations from a session transcript to drive `WordsView` and `Recall Bars` offline.
_Avoid_: Cloud grading, OpenAI assessment schema

**Ephemeral Turn Directive**:
A single replaceable per-turn instruction slot in `PromptBuilder` (used for opening greetings, 15s silence `checkIn`, `help()` restatements, language `redirect`, or pace adjustments) that steers the next on-device turn without accumulating unbounded instruction history in the 4,096-token context window.
_Avoid_: Appended session instructions log



**Meaning Helper**:
The cloud text-only client (backed by Google Gemini REST) that translates English passages into Ukrainian meaning subtitles and resolves tap-to-lookup word details.
_Avoid_: Realtime voice provider, OpenAI helper

**Recall Bars**:
A 0–3 bar heuristic summary (`New`, `Fragile`, `Growing`, `Steady`) of spaced vocabulary retrieval across conversations in `WordsView`.
_Avoid_: Mastery score, fluency percentage, CEFR certificate

**Silence Endpointing**:
The automatic commit of a learner's spoken utterance after ~1.2–1.5 seconds of sustained audio RMS silence and stable on-device ASR partial text.
_Avoid_: Push-to-talk, server VAD

**Half-Duplex Handoff**:
The turn-taking rule where on-device ASR capture pauses while `AVSpeechSynthesizer` speaks (preventing speaker self-transcription) and automatically resumes when speech finishes or when the learner taps the orb/mic to barge in.
_Avoid_: Full-duplex audio stream, acoustic echo cancellation

