module wheatley.client.console.speech.streaming_settings;

import std.algorithm : max;

import wheatley.common.api.audio_playback : AudioPlaybackEventKind;
import wheatley.common.api.session : SessionKey;

struct ConsoleSpeechPlaybackIdentity
{
    SessionKey session;
    string turnId;
    string outputId;
}

struct ConsoleStreamingSpeechSettings
{
    bool enabled;
    string appDataRoot;
    string apiBase;
    string profileId;
    string language;
    string playbackCommand;
    int playbackPrebufferChunks = 2;
    double playbackPrebufferMaxWaitSeconds = 0.35;
    ConsoleSpeechPlaybackIdentity playbackIdentity;
    void delegate(AudioPlaybackEventKind kind, string errorMessage) nothrow onPlaybackEvent;
}

ConsoleStreamingSpeechSettings resolvedSettings(ConsoleStreamingSpeechSettings settings)
{
    settings.playbackPrebufferChunks = max(1, settings.playbackPrebufferChunks);
    settings.playbackPrebufferMaxWaitSeconds = max(0.0, settings.playbackPrebufferMaxWaitSeconds);
    return settings;
}
