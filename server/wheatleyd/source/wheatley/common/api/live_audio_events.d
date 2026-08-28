module wheatley.common.api.live_audio_events;

import std.json : JSONValue;

import wheatley.common.api.conversation_events :
    conversationEventFromJson,
    conversationEventJson;
import wheatley.common.conversation.events : ConversationEvent;
import wheatley.common.api.voice_events : voiceEventFromJson, voiceEventJson;
import wheatley.common.voice.events :
    VoiceEvent,
    VoiceEventKind,
    VoiceFailureEvent,
    VoiceMessageEvent,
    VoicePreviewEvent,
    VoiceReadyEvent,
    VoiceSessionResumeChoiceEvent,
    VoiceTranscriptEvent;
import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;

struct LiveAudioStatus
{
    string kind;
    string message;
}

struct LiveAudioThinkingMusic
{
    string action;
    long delayMs;
}

string liveAudioReadyJson(
    string profileId,
    string submissionId,
    string previewModel,
    double silenceSeconds,
)
{
    VoiceEvent event;
    event.kind = VoiceEventKind.ready;
    event.ready = VoiceReadyEvent(profileId, submissionId, previewModel, silenceSeconds);
    return voiceEventJson(event);
}

string liveAudioListeningJson(VoiceEventKind kind, string message)
{
    VoiceEvent event;
    final switch (kind) {
        case VoiceEventKind.listeningStarted:
        case VoiceEventKind.listeningRetry:
        case VoiceEventKind.listeningSuspended:
        case VoiceEventKind.listeningResumed:
        case VoiceEventKind.candidateRejected:
        case VoiceEventKind.transcriptDraftSelected:
        case VoiceEventKind.audioReceiving:
        case VoiceEventKind.speechDetected:
            break;
        case VoiceEventKind.ready:
        case VoiceEventKind.previewChanged:
        case VoiceEventKind.endpointReached:
        case VoiceEventKind.transcriptAccepted:
        case VoiceEventKind.sessionResumeChoice:
        case VoiceEventKind.failed:
            throw new Exception("Voice event kind does not carry a status message");
    }
    event.kind = kind;
    event.message = VoiceMessageEvent(message);
    return voiceEventJson(event);
}

string liveAudioPreviewTranscriptJson(string text, long candidateId, long revision)
{
    VoiceEvent event;
    event.kind = VoiceEventKind.previewChanged;
    event.preview = VoicePreviewEvent(text, candidateId, revision);
    return voiceEventJson(event);
}

string liveAudioEndpointDetectedJson(string message)
{
    VoiceEvent event;
    event.kind = VoiceEventKind.endpointReached;
    event.message = VoiceMessageEvent(message);
    return voiceEventJson(event);
}

string liveAudioFinalTranscriptJson(
    string text,
    string userText,
    string language,
    string userAudioArtifactId = "",
)
{
    VoiceEvent event;
    event.kind = VoiceEventKind.transcriptAccepted;
    event.transcript = VoiceTranscriptEvent(text, userText, language, userAudioArtifactId);
    return voiceEventJson(event);
}

string liveAudioSessionResumeChoiceJson(string choice, string transcript)
{
    VoiceEvent event;
    event.kind = VoiceEventKind.sessionResumeChoice;
    event.sessionResumeChoice = VoiceSessionResumeChoiceEvent(choice, transcript);
    return voiceEventJson(event);
}

string liveAudioErrorJson(string code, string message)
{
    VoiceEvent event;
    event.kind = VoiceEventKind.failed;
    event.failed = VoiceFailureEvent(code, message);
    return voiceEventJson(event);
}

string liveAudioThinkingMusicJson(string action, long delayMs = 0)
{
    return jsonObject([
        jsonStringField("type", "thinking_music"),
        jsonStringField("action", action),
        jsonLongField("delay_ms", delayMs),
    ]);
}

string liveAudioConversationEventJson(ConversationEvent event)
{
    return jsonObject([
        jsonStringField("type", "conversation_event"),
        jsonRawField("event", conversationEventJson(event)),
    ]);
}

string liveAudioMessageType(JSONValue message)
{
    return Json.object(message).text("type");
}

LiveAudioThinkingMusic liveAudioThinkingMusicFromJson(JSONValue message)
{
    auto json = Json.object(message);
    return LiveAudioThinkingMusic(
        json.choice!("play", "stop")("action"),
        json.integer("delay_ms", 0, 60_000),
    );
}

VoiceEvent liveAudioVoiceEventFromJson(JSONValue message)
{
    return voiceEventFromJson(message);
}

ConversationEvent liveAudioConversationEventFromJson(JSONValue message)
{
    return conversationEventFromJson(Json.object(message).object("event").value);
}
