module wheatley.common.voice.events;

enum VoiceEventKind
{
    ready,
    listeningStarted,
    listeningRetry,
    listeningSuspended,
    listeningResumed,
    candidateRejected,
    transcriptDraftSelected,
    audioReceiving,
    speechDetected,
    previewChanged,
    endpointReached,
    transcriptAccepted,
    sessionResumeChoice,
    failed,
}

struct VoiceReadyEvent
{
    string profileId;
    string submissionId;
    string previewModel;
    double silenceSeconds;
}

struct VoiceMessageEvent
{
    string message;
}

struct VoicePreviewEvent
{
    string text;
    long candidateId;
    long revision;
}

struct VoiceTranscriptEvent
{
    string text;
    string userText;
    string language;
    /// Stable server staging key for the exact normalized accepted `user.opus`.
    /// Empty only for typed (non-recorded) live submissions.
    string userAudioArtifactId;
}

struct VoiceSessionResumeChoiceEvent
{
    string choice;
    string transcript;
}

struct VoiceFailureEvent
{
    string code;
    string message;
}

struct VoiceEvent
{
    VoiceEventKind kind;
    VoiceReadyEvent ready;
    VoiceMessageEvent message;
    VoicePreviewEvent preview;
    VoiceTranscriptEvent transcript;
    VoiceSessionResumeChoiceEvent sessionResumeChoice;
    VoiceFailureEvent failed;
}

string voiceEventKindText(VoiceEventKind kind)
{
    final switch (kind) {
        case VoiceEventKind.ready: return "ready";
        case VoiceEventKind.listeningStarted: return "listening_started";
        case VoiceEventKind.listeningRetry: return "listening_retry";
        case VoiceEventKind.listeningSuspended: return "listening_suspended";
        case VoiceEventKind.listeningResumed: return "listening_resumed";
        case VoiceEventKind.candidateRejected: return "candidate_rejected";
        case VoiceEventKind.transcriptDraftSelected: return "transcript_draft_selected";
        case VoiceEventKind.audioReceiving: return "audio_receiving";
        case VoiceEventKind.speechDetected: return "speech_detected";
        case VoiceEventKind.previewChanged: return "preview_changed";
        case VoiceEventKind.endpointReached: return "endpoint_reached";
        case VoiceEventKind.transcriptAccepted: return "transcript_accepted";
        case VoiceEventKind.sessionResumeChoice: return "session_resume_choice";
        case VoiceEventKind.failed: return "failed";
    }
}

VoiceEventKind parseVoiceEventKind(string value)
{
    switch (value) {
        case "ready": return VoiceEventKind.ready;
        case "listening_started": return VoiceEventKind.listeningStarted;
        case "listening_retry": return VoiceEventKind.listeningRetry;
        case "listening_suspended": return VoiceEventKind.listeningSuspended;
        case "listening_resumed": return VoiceEventKind.listeningResumed;
        case "candidate_rejected": return VoiceEventKind.candidateRejected;
        case "transcript_draft_selected": return VoiceEventKind.transcriptDraftSelected;
        case "audio_receiving": return VoiceEventKind.audioReceiving;
        case "speech_detected": return VoiceEventKind.speechDetected;
        case "preview_changed": return VoiceEventKind.previewChanged;
        case "endpoint_reached": return VoiceEventKind.endpointReached;
        case "transcript_accepted": return VoiceEventKind.transcriptAccepted;
        case "session_resume_choice": return VoiceEventKind.sessionResumeChoice;
        case "failed": return VoiceEventKind.failed;
        default: throw new Exception("Unsupported Voice event kind: " ~ value);
    }
}
