module wheatley.server.turns.audio.live_audio_messages;

import std.exception : enforce;
import std.json : parseJSON;

import vibe.http.websockets :
    FrameOpcode,
    IncomingWebSocketMessage,
    WebSocket;
import vibe.stream.operations : readAllUTF8;

import wheatley.common.api.live_audio :
    LiveAudioCommit,
    LiveAudioStartRequest,
    liveAudioCommitFromJson,
    liveAudioStartFromJson;
import wheatley.common.api.live_audio_events : liveAudioConversationEventJson;
import wheatley.common.conversation.events : ConversationEvent;
import wheatley.common.json.read : Json;

struct LiveAudioCommand
{
    string kind;
    int silenceSeconds;
}

LiveAudioStartRequest readStartMessage(scope WebSocket socket)
{
    string data;
    while (socket.connected && socket.waitForData()) {
        socket.receive(delegate(scope IncomingWebSocketMessage message) @trusted {
            enforce(message.frameOpcode == FrameOpcode.text, "Live audio start message must be text JSON");
            data = message.readAllUTF8();
        });
        if (data.length) break;
    }
    enforce(data.length, "Live audio start message is required");

    return liveAudioStartFromJson(parseJSON(data));
}

LiveAudioCommit readLiveAudioCommit(scope WebSocket socket)
{
    while (socket.connected && socket.waitForData()) {
        string data;
        socket.receive(delegate(scope IncomingWebSocketMessage message) @trusted {
            if (message.frameOpcode == FrameOpcode.text)
                data = message.readAllUTF8();
        });
        if (!data.length) continue;
        auto payload = parseJSON(data);
        auto kind = Json.object(payload).text("type");
        if (kind == "stop" || kind == "configure" || kind == "suspend" || kind == "resume") {
            readLiveAudioCommand(data);
            continue;
        }
        return liveAudioCommitFromJson(payload);
    }
    enforce(false, "Live audio commit message is required");
    assert(false);
}

LiveAudioCommand readLiveAudioCommand(string data)
{
    auto payloadJson = Json.parse(data);
    auto kind = payloadJson.choice!("stop", "cancel", "configure", "suspend", "resume")("type");
    if (kind == "stop") return LiveAudioCommand(kind, 0);
    if (kind == "cancel") return LiveAudioCommand(kind, 0);
    if (kind == "suspend" || kind == "resume") return LiveAudioCommand(kind, 0);
    return LiveAudioCommand(kind, payloadJson.intRange("silence_seconds", 1, 12));
}

void sendTurnEvent(scope WebSocket socket, ConversationEvent event)
{
    sendSocket(socket, liveAudioConversationEventJson(event));
}

void sendSocket(scope WebSocket socket, string payload)
{
    try {
        if (socket.connected) socket.send(payload);
    } catch (Exception) {
    }
}

unittest
{
    auto configure = readLiveAudioCommand(
        `{"type":"configure","silence_seconds":7}`,
    );
    assert(configure.kind == "configure");
    assert(configure.silenceSeconds == 7);
    assert(readLiveAudioCommand(`{"type":"stop"}`).kind == "stop");
    assert(readLiveAudioCommand(`{"type":"cancel"}`).kind == "cancel");
    assert(readLiveAudioCommand(`{"type":"suspend"}`).kind == "suspend");
}
