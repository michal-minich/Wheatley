module wheatley.server.api.runtime.detached_conversation;

import core.time : dur;
import vibe.core.channel : Channel, createChannel;
import vibe.core.core : runTask;
import vibe.http.server : HTTPServerResponse;

import wheatley.common.api.conversation_events : conversationEventJson;
import wheatley.common.api.session : SessionKey;
import wheatley.common.conversation.events :
    ConversationEvent,
    ConversationEventKind,
    ConversationEventSink;
import wheatley.server.api.http.sse : startSse, writeSse;
import wheatley.server.api.http.json_response : apiErrorJson;
import wheatley.server.session_use_registry : SessionUseRegistry;

alias DetachedConversationStart = void delegate(ConversationEventSink sink);

/** Carries live events while durable Conversation execution runs separately. */
private final class ConversationEventRelay
{
    private Channel!(ConversationEvent, 128) events;
    private bool closed;
    private bool finished;
    private string failure;

    this()
    {
        events = createChannel!(ConversationEvent, 128)();
    }

    void publish(ConversationEvent event) nothrow
    {
        if (closed) return;
        try {
            events.put(event);
        } catch (Throwable) {
            // Observer disconnects must never stop durable execution.
        }
    }

    bool next(ref ConversationEvent event)
    {
        while (!finished) {
            if (events.tryConsumeOne(event, dur!"msecs"(250))) return true;
        }
        return events.tryConsumeOne(event);
    }

    void finish() nothrow
    {
        finished = true;
        events.close();
    }

    void close() nothrow
    {
        closed = true;
        events.close();
    }

    void fail(string message) nothrow
    {
        failure = message.length ? message : "Conversation execution failed.";
    }

    @property bool observerClosed() const { return closed; }

    @property string failureMessage() const { return failure; }
}

/**
 * Follows a Conversation while the producer owns the session use until its
 * durable queue/history work is complete. Closing the HTTP observer only
 * closes the bounded live relay.
 */
void streamDetachedConversation(
    HTTPServerResponse res,
    string corsOrigin,
    SessionUseRegistry sessionUses,
    SessionKey session,
    DetachedConversationStart start,
)
{
    auto relay = new ConversationEventRelay;
    startSse(res, corsOrigin);
    runTask(() nothrow {
        try {
            start((event) { relay.publish(event); });
        } catch (Throwable error) {
            // Normal Conversation implementations materialize a terminal
            // failure event. Adapters failing before a turn exists have no
            // safe synthetic event for this observer.
            relay.fail(error.msg);
        } finally {
            finishSessionUseQuietly(sessionUses, session);
            relay.finish();
        }
    });

    try {
        ConversationEvent event;
        while (relay.next(event)) {
            if (!writeSse(res, "conversation", conversationEventJson(event))) {
                relay.close();
                break;
            }
            if (event.kind == ConversationEventKind.completed
                || event.kind == ConversationEventKind.failed) {
                relay.close();
                break;
            }
        }
        if (!relay.observerClosed && relay.failureMessage.length)
            writeSse(res, "error", apiErrorJson("conversation", relay.failureMessage));
    } catch (Throwable) {
        relay.close();
    } finally {
        finalizeObserverQuietly(res);
    }
}

private void finishSessionUseQuietly(SessionUseRegistry sessionUses, SessionKey session) nothrow
{
    try {
        sessionUses.finish(session);
    } catch (Exception) {
    }
}

private void finalizeObserverQuietly(HTTPServerResponse res)
{
    try {
        if (res.headerWritten) res.finalize();
    } catch (Exception) {
    }
}
