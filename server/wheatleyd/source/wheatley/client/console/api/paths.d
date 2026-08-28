module wheatley.client.console.api.paths;

import std.string : startsWith, strip;
import std.uri : encodeComponent;

string textTurnStreamUrl(string apiBase, string profileId)
{
    return joinApiPath(apiBase, "/profiles/" ~ encodeComponent(profileId) ~ "/turns/text/stream");
}

string acceptedVoiceCommitStreamUrl(string apiBase, string profileId, string submissionId)
{
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId) ~
            "/accepted-voice/" ~ encodeComponent(submissionId) ~ "/commit/stream",
    );
}

string profileStartupStreamUrl(string apiBase, string profileId)
{
    return joinApiPath(apiBase, "/profiles/" ~ encodeComponent(profileId) ~ "/startup/stream");
}

string profileStartupUrl(string apiBase, string profileId, string language)
{
    auto url = joinApiPath(apiBase, "/profiles/" ~ encodeComponent(profileId) ~ "/startup");
    return language.length ? url ~ "?language=" ~ encodeComponent(language) : url;
}

string ttsUrl(string apiBase, string profileId)
{
    return joinApiPath(apiBase, "/profiles/" ~ encodeComponent(profileId) ~ "/tts");
}

string speechInterruptUrl(string apiBase, string profileId)
{
    return joinApiPath(apiBase, "/profiles/" ~ encodeComponent(profileId) ~ "/speech-interrupt/transcribe");
}

string stopTextTurnUrl(string apiBase, string profileId, string turnId)
{
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId) ~
            "/turns/text/" ~ encodeComponent(turnId) ~ "/stop",
    );
}

string generatedAudioUrl(string apiBase, string value)
{
    auto clean = value.strip;
    if (clean.startsWith("http://") || clean.startsWith("https://")) return clean;
    if (clean.startsWith("/")) return apiOrigin(apiBase) ~ clean;
    return joinApiPath(apiBase, clean);
}

string turnClientMetricsUrl(string apiBase, string profileId, string turnId)
{
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId) ~
            "/turns/" ~ encodeComponent(turnId) ~ "/client-metrics",
    );
}

string clientToolClientsUrl(string apiBase, string profileId)
{
    return joinApiPath(apiBase, "/profiles/" ~ encodeComponent(profileId) ~ "/client-tools/clients");
}

string clientToolRequestsUrl(string apiBase, string profileId)
{
    return joinApiPath(apiBase, "/profiles/" ~ encodeComponent(profileId) ~ "/client-tools/requests");
}

string clientToolRequestResultUrl(string apiBase, string profileId, string requestId)
{
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId) ~
            "/client-tools/requests/" ~ encodeComponent(requestId) ~ "/result",
    );
}

string clientToolArtifactUploadUrl(string apiBase, string profileId, string requestId)
{
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId) ~
            "/client-tools/requests/" ~ encodeComponent(requestId) ~ "/artifacts",
    );
}

string liveAudioTurnUrl(string apiBase, string profileId)
{
    auto url = joinApiPath(apiBase, "/profiles/" ~ encodeComponent(profileId) ~ "/turns/audio/live");
    if (url.startsWith("http://")) return "ws://" ~ url["http://".length .. $];
    if (url.startsWith("https://")) return "wss://" ~ url["https://".length .. $];
    return url;
}

string clientConfigUrl(string apiBase, string clientId)
{
    return joinApiPath(apiBase, "/config/clients/" ~ encodeComponent(clientId));
}

string thinkingMusicUrl(string apiBase, string profileId)
{
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId) ~ "/thinking-music",
    );
}

string audioPlaybackEventsUrl(string apiBase, string profileId)
{
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId) ~ "/audio/playback-events",
    );
}

string sessionPresentationUrl(string apiBase, string profileId, string sessionId)
{
    import std.uri : encodeComponent;
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId)
            ~ "/presentation?session_id=" ~ encodeComponent(sessionId),
    );
}

string sessionQueueUrl(string apiBase, string profileId, string sessionId)
{
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId)
            ~ "/queue?session_id=" ~ encodeComponent(sessionId),
    );
}

string sessionTurnEventsUrl(
    string apiBase,
    string profileId,
    string sessionId,
    long afterSequence,
)
{
    import std.conv : to;
    import std.uri : encodeComponent;
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId)
            ~ "/session-turns/stream?session_id=" ~ encodeComponent(sessionId)
            ~ "&after_sequence=" ~ afterSequence.to!string,
    );
}

string codexEventsUrl(
    string apiBase,
    string profileId,
    string sessionId,
    long afterSequence,
)
{
    import std.conv : to;
    import std.uri : encodeComponent;
    return joinApiPath(
        apiBase,
        "/profiles/" ~ encodeComponent(profileId)
            ~ "/codex/events?session_id=" ~ encodeComponent(sessionId)
            ~ "&after_sequence=" ~ afterSequence.to!string,
    );
}

private string joinApiPath(string base, string path)
{
    auto clean = base.strip;
    while (clean.length && clean[$ - 1] == '/') clean = clean[0 .. $ - 1];
    return clean ~ path;
}

private string apiOrigin(string url)
{
    auto protocolEnd = -1;
    if (url.length >= 3) {
        foreach (index; 0 .. url.length - 2) {
            if (url[index .. index + 3] == "://") {
                protocolEnd = cast(int) index + 3;
                break;
            }
        }
    }
    if (protocolEnd < 0) return url;
    foreach (index; cast(size_t) protocolEnd .. url.length) {
        if (url[index] == '/') return url[0 .. index];
    }
    return url;
}
