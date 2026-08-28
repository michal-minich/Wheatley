module wheatley.common.api.voice_events;

import std.conv : to;
import std.json : JSONValue;

import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.voice.events :
    VoiceEvent,
    VoiceEventKind,
    VoiceFailureEvent,
    VoiceMessageEvent,
    VoicePreviewEvent,
    VoiceReadyEvent,
    VoiceSessionResumeChoiceEvent,
    VoiceTranscriptEvent,
    parseVoiceEventKind,
    voiceEventKindText;

string voiceEventJson(VoiceEvent event)
{
    return jsonObject([
        jsonStringField("type", "voice_event"),
        jsonStringField("kind", voiceEventKindText(event.kind)),
        jsonRawField("payload", voiceEventPayloadJson(event)),
    ]);
}

VoiceEvent voiceEventFromJson(JSONValue value)
{
    auto json = Json.object(value);
    json.choice!("voice_event")("type");
    VoiceEvent event;
    event.kind = parseVoiceEventKind(json.text("kind"));
    auto payload = json.object("payload");
    final switch (event.kind) {
        case VoiceEventKind.ready:
            event.ready = VoiceReadyEvent(
                payload.text("profile_id"),
                payload.nonEmpty("submission_id"),
                payload.text("preview_model"),
                payload.number("silence_seconds", 0, 12),
            );
            break;
        case VoiceEventKind.listeningStarted:
        case VoiceEventKind.listeningRetry:
        case VoiceEventKind.listeningSuspended:
        case VoiceEventKind.listeningResumed:
        case VoiceEventKind.candidateRejected:
        case VoiceEventKind.transcriptDraftSelected:
        case VoiceEventKind.audioReceiving:
        case VoiceEventKind.speechDetected:
        case VoiceEventKind.endpointReached:
            event.message = VoiceMessageEvent(payload.text("message"));
            break;
        case VoiceEventKind.previewChanged:
            event.preview = VoicePreviewEvent(
                payload.text("text"),
                payload.positiveInt("candidate_id"),
                payload.positiveInt("revision"),
            );
            break;
        case VoiceEventKind.transcriptAccepted:
            event.transcript = VoiceTranscriptEvent(
                payload.text("text"),
                payload.text("user_text"),
                payload.token("language"),
                payload.text("user_audio_artifact_id"),
            );
            break;
        case VoiceEventKind.sessionResumeChoice:
            event.sessionResumeChoice = VoiceSessionResumeChoiceEvent(
                payload.choice!("yes", "no", "unclear")("choice"),
                payload.text("transcript"),
            );
            break;
        case VoiceEventKind.failed:
            event.failed = VoiceFailureEvent(
                payload.text("code"),
                payload.text("message"),
            );
            break;
    }
    return event;
}

private string voiceEventPayloadJson(VoiceEvent event)
{
    final switch (event.kind) {
        case VoiceEventKind.ready:
            return jsonObject([
                jsonStringField("profile_id", event.ready.profileId),
                jsonStringField("submission_id", event.ready.submissionId),
                jsonStringField("preview_model", event.ready.previewModel),
                jsonRawField("silence_seconds", event.ready.silenceSeconds.to!string),
            ]);
        case VoiceEventKind.listeningStarted:
        case VoiceEventKind.listeningRetry:
        case VoiceEventKind.listeningSuspended:
        case VoiceEventKind.listeningResumed:
        case VoiceEventKind.candidateRejected:
        case VoiceEventKind.transcriptDraftSelected:
        case VoiceEventKind.audioReceiving:
        case VoiceEventKind.speechDetected:
        case VoiceEventKind.endpointReached:
            return jsonObject([jsonStringField("message", event.message.message)]);
        case VoiceEventKind.previewChanged:
            return jsonObject([
                jsonStringField("text", event.preview.text),
                jsonLongField("candidate_id", event.preview.candidateId),
                jsonLongField("revision", event.preview.revision),
            ]);
        case VoiceEventKind.transcriptAccepted:
            return jsonObject([
                jsonStringField("text", event.transcript.text),
                jsonStringField("user_text", event.transcript.userText),
                jsonStringField("language", event.transcript.language),
                jsonStringField("user_audio_artifact_id", event.transcript.userAudioArtifactId),
            ]);
        case VoiceEventKind.sessionResumeChoice:
            return jsonObject([
                jsonStringField("choice", event.sessionResumeChoice.choice),
                jsonStringField("transcript", event.sessionResumeChoice.transcript),
            ]);
        case VoiceEventKind.failed:
            return jsonObject([
                jsonStringField("code", event.failed.code),
                jsonStringField("message", event.failed.message),
            ]);
    }
}

unittest
{
    import std.json : parseJSON;

    VoiceEvent event;
    event.kind = VoiceEventKind.ready;
    event.ready = VoiceReadyEvent("tester", "submission-1", "whisper", 4.0);
    auto decoded = voiceEventFromJson(parseJSON(voiceEventJson(event)));
    assert(decoded.kind == VoiceEventKind.ready);
    assert(decoded.ready.submissionId == "submission-1");
    assert(decoded.ready.silenceSeconds == 4.0);

    event.kind = VoiceEventKind.transcriptAccepted;
    event.transcript = VoiceTranscriptEvent(
        "Hello", "Hello", "en", "runtime-user-audio:submission-1",
    );
    decoded = voiceEventFromJson(parseJSON(voiceEventJson(event)));
    assert(decoded.kind == VoiceEventKind.transcriptAccepted);
    assert(decoded.transcript.userText == "Hello");
    assert(decoded.transcript.userAudioArtifactId == "runtime-user-audio:submission-1");
}
