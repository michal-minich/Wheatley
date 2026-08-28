module wheatley.server.codex.port;

import wheatley.common.api.session : SessionKey;
import wheatley.server.codex.types :
    CodexLiveEvent,
    CodexMessageResult,
    CodexStatusResult;

interface CodexSessionPort
{
    CodexMessageResult message(
        SessionKey session,
        string sessionRoot,
        string piTurnId,
        string value,
    );

    CodexStatusResult status(SessionKey session, string sessionRoot);

    CodexLiveEvent[] eventsAfter(
        SessionKey session,
        string sessionRoot,
        long afterSequence,
        long limit = 200,
    );

    void shutdown();
}
