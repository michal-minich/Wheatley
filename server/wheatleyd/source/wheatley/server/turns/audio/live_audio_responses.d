module wheatley.server.turns.audio.live_audio_responses;

import vibe.http.websockets : WebSocket;

import wheatley.common.api.live_audio : LiveAudioStartRequest;
import wheatley.common.api.live_audio_events :
    liveAudioEndpointDetectedJson,
    liveAudioErrorJson,
    liveAudioFinalTranscriptJson,
    liveAudioListeningJson,
    liveAudioPreviewTranscriptJson,
    liveAudioReadyJson,
    liveAudioSessionResumeChoiceJson;
import wheatley.common.api.live_audio_events : liveAudioThinkingMusicJson;
import wheatley.server.i18n.product_translations : productTranslationText;
import wheatley.server.turns.audio.live_audio_messages : sendSocket;
import wheatley.server.turns.audio.live_audio_settings : LiveAudioRuntimeSettings;
import wheatley.common.voice.events : VoiceEventKind;

void sendLiveReady(
    scope WebSocket socket,
    string profileId,
    LiveAudioStartRequest start,
    LiveAudioRuntimeSettings settings,
)
{
    sendSocket(socket, liveAudioReadyJson(
        profileId,
        start.submissionId,
        settings.previewStt.model,
        settings.silenceSeconds,
    ));
}

void sendLiveStatus(
    scope WebSocket socket,
    string resourcesRoot,
    string language,
    VoiceEventKind kind,
    string messageKey,
)
{
    sendSocket(socket, liveAudioListeningJson(
        kind,
        liveProductText(resourcesRoot, language, messageKey),
    ));
}

void sendLivePreviewTranscript(
    scope WebSocket socket,
    string text,
    long candidateId,
    long revision,
)
{
    if (!text.length) return;
    sendSocket(socket, liveAudioPreviewTranscriptJson(text, candidateId, revision));
}

void sendLiveEndpointDetected(
    scope WebSocket socket,
    string resourcesRoot,
    string language,
    string messageKey,
)
{
    sendSocket(socket, liveAudioEndpointDetectedJson(
        liveProductText(resourcesRoot, language, messageKey),
    ));
}

void sendLiveThinkingMusic(scope WebSocket socket, string action, long delayMs = 0)
{
    sendSocket(socket, liveAudioThinkingMusicJson(action, delayMs));
}

void sendLiveFinalTranscript(
    scope WebSocket socket,
    string text,
    string userText,
    string language,
    string userAudioArtifactId = "",
)
{
    sendSocket(socket, liveAudioFinalTranscriptJson(text, userText, language, userAudioArtifactId));
}

void sendLiveSessionResumeChoice(scope WebSocket socket, string choice, string transcript)
{
    sendSocket(socket, liveAudioSessionResumeChoiceJson(choice, transcript));
}

void sendLiveError(scope WebSocket socket, string message)
{
    sendSocket(socket, liveAudioErrorJson("live_audio", message));
}

void sendLiveError(
    scope WebSocket socket,
    string resourcesRoot,
    string language,
    string messageKey,
)
{
    sendLiveError(socket, liveProductText(resourcesRoot, language, messageKey));
}

private string liveProductText(string resourcesRoot, string language, string key)
{
    return productTranslationText(resourcesRoot, language, "speech.live." ~ key);
}
