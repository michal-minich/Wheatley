module wheatley.server.conversation.port;

import wheatley.common.api.session : SessionKey;
import wheatley.common.conversation.events : ConversationEventSink;
import wheatley.server.conversation.preparation : ConversationPreparation;
import wheatley.server.conversation.turn_request : ConversationTurnRequest;
import wheatley.server.history.rows.audio_artifact_record : UserAudioArtifactRecord;
import wheatley.server.queue.session_queue : QueueMutation, QueueReservation;

/// Optional preparation owned by the selected Conversation placement.
interface ConversationPromptPrewarm
{
    string waitMetricsJson();
    void stop();
}

/// Preparation policy paired with the selected Conversation placement.
interface ConversationPreparationPort
{
    bool performsLocalAgentStartup();

    ConversationPreparation beginSessionPreparation(SessionKey session);
    void finishSessionPreparation(
        SessionKey session,
        ConversationPreparation preparation,
        string error = "",
    );

    ConversationPromptPrewarm startPromptPrewarm(
        SessionKey session,
        string language,
        bool loadMemory,
        bool prewarmExistingSession,
    );
}

/// One fixed Conversation execution capability selected by the composition root.
interface ConversationPort
{
    /** Queue operations travel with Conversation placement so a remote setup
        still has exactly one admission and cancellation authority. */
    string queueSnapshotJson(SessionKey session);
    QueueMutation reserveQueueItem(SessionKey session, QueueReservation reservation);
    QueueMutation touchQueuePreparation(
        SessionKey session,
        string itemId,
        string progressAt,
        string deadlineAt = "",
    );
    QueueMutation failQueuePreparation(SessionKey session, string itemId, string failure);
    QueueMutation cancelQueueItem(SessionKey session, string itemId);
    void compactQueue(SessionKey session);

    void run(
        SessionKey session,
        ConversationTurnRequest request,
        ConversationEventSink sink,
        string fallbackSource = "api_text",
        ConversationPromptPrewarm promptPrewarm = null,
    );

    void runWithUserAudio(
        SessionKey session,
        ConversationTurnRequest request,
        UserAudioArtifactRecord userAudio,
        ConversationEventSink sink,
        string fallbackSource = "api_text",
        ConversationPromptPrewarm promptPrewarm = null,
    );

    /** Wake the daemon-owned session dispatcher after a durable queue change. */
    void wake(SessionKey session);

    void stop(SessionKey session, string turnId);
    string compact(SessionKey session);
    void shutdown();
}
