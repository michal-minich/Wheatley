module wheatley.server.conversation.remote_peer;

import wheatley.common.api.reasoning : ReasoningMode;
import wheatley.common.api.session : SessionKey;
import wheatley.common.api.text_turn : TextTurnRequest;
import wheatley.common.conversation.events : ConversationEventSink;
import wheatley.server.queue.session_queue : QueueMutation, QueueReservation;

/// Conversation authority transport used by the remote placement adapter.
interface RemoteConversationPeer
{
    string queueSnapshotJson(SessionKey session);
    QueueMutation reserveQueueItem(SessionKey session, QueueReservation reservation);
    QueueMutation touchQueuePreparation(
        SessionKey session,
        string itemId,
        string progressAt,
        string deadlineAt,
    );
    QueueMutation failQueuePreparation(SessionKey session, string itemId, string failure);
    QueueMutation cancelQueueItem(SessionKey session, string itemId);
    void compactQueue(SessionKey session);

    void streamText(
        string profileId,
        TextTurnRequest request,
        ConversationEventSink sink,
    );

    void streamAcceptedVoice(
        string profileId,
        string submissionId,
        ReasoningMode reasoningMode,
        string model,
        long afterSequence,
        ConversationEventSink sink,
    );

    void stop(SessionKey session, string turnId);
}
