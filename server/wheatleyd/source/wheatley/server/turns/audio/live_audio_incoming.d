module wheatley.server.turns.audio.live_audio_incoming;

import vibe.http.websockets :
    FrameOpcode,
    IncomingWebSocketMessage,
    WebSocket;
import vibe.stream.operations : readAll, readAllUTF8;

struct LiveAudioIncoming
{
    ubyte[] audioBytes;
    string commandText;
}

LiveAudioIncoming readLiveAudioIncoming(scope WebSocket socket)
{
    LiveAudioIncoming incoming;
    socket.receive(delegate(scope IncomingWebSocketMessage message) @trusted {
        if (message.frameOpcode == FrameOpcode.binary) {
            incoming.audioBytes = message.readAll();
            return;
        }
        if (message.frameOpcode == FrameOpcode.text) {
            incoming.commandText = message.readAllUTF8();
        }
    });
    return incoming;
}
