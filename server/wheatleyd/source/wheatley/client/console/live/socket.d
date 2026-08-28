module wheatley.client.console.live.socket;

import vibe.http.websockets : WebSocket;

void closeSocketQuietly(scope WebSocket ws, short code, string reason) nothrow
{
    try {
        ws.close(code, reason);
    } catch (Throwable) {
    }
}
