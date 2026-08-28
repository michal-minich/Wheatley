module wheatley.client.console.voice.session_resume;

import std.exception : enforce;
import std.uuid : randomUUID;

import wheatley.client.console.api.client : ConsoleApiClient;
import wheatley.client.console.audio.runtime : ConsoleAudioRuntime;
import wheatley.client.console.config : ConsoleConfig;
import wheatley.client.console.live.client : streamLiveAudioTurn;
import wheatley.client.console.live.types :
    ConsoleLiveAudioHandlers,
    ConsoleLiveAudioRequest;
import wheatley.client.console.ui.output : writeTurn;
import wheatley.client.console.ui.output : LivePreviewLine;
import wheatley.client.console.ui.system_announcement : sayConsoleSystem;
import wheatley.common.api.live_audio : LiveAudioStartRequest;
import wheatley.common.api.text_turn : TextTurnRequest;
import wheatley.common.api.profile_startup : ProfileStartupState;

bool promptConsoleVoiceSessionResume(
    ConsoleApiClient client,
    ConsoleAudioRuntime audio,
    ConsoleConfig config,
    ProfileStartupState startup,
    string ffmpegPath,
)
{
    bool firstAttempt = true;
    while (true) {
        speakSessionResumePrompt(audio, config, startup, firstAttempt);

        auto previewLine = new LivePreviewLine;
        bool listeningChimePlayed;
        bool stopChimePlayed;
        ConsoleLiveAudioRequest request;
        request.start = LiveAudioStartRequest(
            TextTurnRequest(
                startup.lastSessionId,
                "",
                "console-session-resume-" ~ randomUUID().toString(),
                config.deviceId,
                config.language,
                "",
                false,
            ),
            config.audio,
            "session_resume",
            false,
        );
        request.ffmpegPath = ffmpegPath;
        request.ffmpegAudioInput = config.audioInput;
        request.simulateUploadKbps = config.simulateUploadKbps;

        auto result = streamLiveAudioTurn(
            config.apiBase,
            config.profileId,
            request,
            ConsoleLiveAudioHandlers(
                (status) {
                    if (status.kind == "listening_started" && !listeningChimePlayed) {
                        previewLine.begin("you", "yellow");
                        audio.beginCapture();
                        audio.playListeningStart();
                        listeningChimePlayed = true;
                    }
                    if (status.kind == "endpoint_reached" && !stopChimePlayed) {
                        audio.releaseCapture();
                        audio.playListeningStop();
                        stopChimePlayed = true;
                    }
                },
                (text) {
                    previewLine.update("you", "yellow", text);
                },
            ),
        );
        if (!stopChimePlayed) {
            audio.releaseCapture();
            audio.playListeningStop();
        }
        if (result.sessionResumeTranscript.length) {
            previewLine.completeTurn("you", "yellow", result.sessionResumeTranscript);
        } else {
            previewLine.clear();
        }

        if (result.sessionResumeChoice == "yes") return true;
        if (result.sessionResumeChoice == "no") return false;
        enforce(
            result.sessionResumeChoice == "unclear",
            "Unsupported session resume choice: " ~ result.sessionResumeChoice,
        );
        firstAttempt = false;
    }
}

private void speakSessionResumePrompt(
    ConsoleAudioRuntime audio,
    ConsoleConfig config,
    ProfileStartupState startup,
    bool firstAttempt,
)
{
    auto message = firstAttempt
        ? startup.messages.voiceResumePrompt
        : startup.messages.voiceResumeUnclear;
    writeTurn(config.profileId, message);
    sayConsoleSystem(audio, config, message);
}
