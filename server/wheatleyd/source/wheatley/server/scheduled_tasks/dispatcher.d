module wheatley.server.scheduled_tasks.dispatcher;

import std.exception : enforce;

import vibe.core.log : logWarn;

import wheatley.common.api.reasoning :
    nearestReasoningMode,
    parseReasoningMode,
    reasoningModeText;
import wheatley.common.api.session : SessionKey;
import wheatley.common.api.text_turn : TextTurnRequest, newSubmissionId;
import wheatley.common.conversation.events : ConversationEventKind;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.server.conversation.port : ConversationPort;
import wheatley.server.conversation.turn_request : conversationTurnRequest;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.pi.models : PiModels;
import wheatley.server.scheduled_tasks.presence : ActiveChatPresenceRegistry;
import wheatley.server.scheduled_tasks.store : ScheduledTaskFile, ScheduledTaskStore;

/** Claims one due occurrence, freezes its provenance, resolves its target, and
    hands the occurrence to Conversation Runtime. Timer polling is deliberately
    kept out of this operation. */
final class ScheduledTaskDispatcher
{
    private HistoryStore history;
    private ScheduledTaskStore tasks;
    private ConversationPort conversations;
    private ActiveChatPresenceRegistry presence;
    private PiModels models;

    this(
        HistoryStore history,
        ScheduledTaskStore tasks,
        ConversationPort conversations,
        ActiveChatPresenceRegistry presence,
        PiModels models,
    )
    {
        this.history = history;
        this.tasks = tasks;
        this.conversations = conversations;
        this.presence = presence;
        this.models = models;
    }

    void dispatch(ScheduledTaskFile file)
    {
        auto claimedAt = nowIso();
        if (Json.object(file.task).object("target").text("kind") == "active_user_session") {
            // Voice owns a microphone turn until its browser acknowledges this
            // in-memory yield request. Do not claim first: an unacknowledged
            // request must leave the occurrence fully durable and retryable.
            if (presence.requestVoiceYield(file.profileId, claimedAt)) return;
            if (presence.hasBlockingVoice(file.profileId, claimedAt)) return;
            if (!presence.activeSessionId(file.profileId, claimedAt).length) return;
        }
        auto submissionId = newSubmissionId("scheduled-task");
        auto occurrenceId = tasks.claim(file, claimedAt, submissionId);
        if (!occurrenceId.length) return;
        SessionKey session;
        try {
            auto task = Json.object(file.task);
            auto configuredMode = parseReasoningMode(task.text("reasoning_mode"));
            if (task.object("target").text("kind") == "new_session")
                models.requireExactReasoning(task.object("target").text("model"), configuredMode);
            session = resolveSession(file, claimedAt);
            auto requestedModel = task.object("target").opt.textOrEmpty("model");
            auto activeModel = requestedModel.length
                ? requestedModel : history.sessionModel(session);
            auto effectiveMode = task.object("target").text("kind") == "new_session"
                ? configuredMode
                : nearestReasoningMode(
                    models.chatModel(activeModel).reasoningModes,
                    configuredMode,
                );
            if (task.object("target").text("kind") == "new_session")
                history.markScheduledSessionOrigin(session, file.id, occurrenceId);
            auto trigger = file.manual
                ? (task.text("state") == "needs_attention" ? "retry" : "manual")
                : "scheduled";
            auto request = conversationTurnRequest(TextTurnRequest(
                session.sessionId,
                task.text("task_text"),
                submissionId,
                "scheduler",
                history.sessionLanguage(session),
                "scheduled_task",
                false,
                configuredMode,
                requestedModel,
                0,
            ));
            auto schedulerContext = jsonObject([
                jsonRawField("scheduled_task", jsonObject([
                    jsonStringField("id", file.id),
                    jsonStringField("display_text", task.text("display_text")),
                    jsonStringField("target", task.object("target").text("kind")),
                    jsonStringField("schedule_kind", task.object("schedule").text("kind")),
                    jsonStringField("scheduled_for", file.dueAt),
                    jsonStringField("agent_started_at", claimedAt),
                    file.missedOccurrences
                        ? jsonLongField("missed_occurrences", file.missedOccurrences) : "",
                    file.missedSince.length
                        ? jsonStringField("missed_since", file.missedSince) : "",
                    jsonBoolField("manual_extra_occurrence", file.manual
                        && task.object("schedule").text("kind") != "after_completion"
                        && task.text("state") != "needs_attention"),
                ])),
            ]);
            request.scheduledTriggerJson = jsonObject([
                jsonStringField("task_id", file.id),
                jsonStringField("occurrence_id", occurrenceId),
                jsonStringField("trigger", trigger),
                jsonStringField("display_text", task.text("display_text")),
            ]);
            request.scheduledTriggerDetailsJson = jsonObject([
                jsonRawField("target", task.object("target").value.toString()),
                jsonRawField("schedule", task.object("schedule").value.toString()),
                jsonStringField("configured_reasoning_mode", task.text("reasoning_mode")),
                jsonStringField("scheduled_for", file.dueAt),
                jsonStringField("agent_started_at", claimedAt),
                file.missedOccurrences
                    ? jsonLongField("missed_occurrences", file.missedOccurrences) : "",
                file.missedSince.length
                    ? jsonStringField("missed_since", file.missedSince) : "",
                jsonBoolField("manual_extra_occurrence", file.manual
                    && task.object("schedule").text("kind") != "after_completion"
                    && task.text("state") != "needs_attention"),
                jsonRawField("injected_prompt", "[" ~ jsonObject([
                    jsonStringField("kind", "task_request"),
                    jsonStringField("placement", "current_request"),
                    jsonStringField("text", task.text("task_text")),
                ]) ~ "," ~ jsonObject([
                    jsonStringField("kind", "scheduler_context"),
                    jsonStringField("placement", "private_context"),
                    jsonStringField("text", schedulerContext),
                ]) ~ "]"),
            ]);
            request.scheduledPrivatePrompt = schedulerContext;
            string conversationFailure;
            conversations.run(session, request, (event) {
                if (event.kind == ConversationEventKind.failed)
                    conversationFailure = event.failed.message;
            }, "scheduled_task");
            auto turn = history.findTurnBySubmission(session, submissionId);
            if (conversationFailure.length || !turn.id.length) {
                tasks.finish(
                    file,
                    "failed",
                    nowIso(),
                    session.sessionId,
                    turn.id,
                    task.text("reasoning_mode"),
                    reasoningModeText(turn.id.length ? turn.reasoningMode : effectiveMode),
                    conversationFailure.length
                        ? conversationFailure : "Scheduled Conversation produced no durable turn.",
                );
                return;
            }
            tasks.finish(
                file,
                turn.status == "completed" || turn.status == "stopped"
                    ? "completed" : "failed",
                nowIso(),
                session.sessionId,
                turn.id,
                task.text("reasoning_mode"),
                reasoningModeText(turn.reasoningMode),
            );
        } catch (Exception error) {
            logWarn("Scheduled task %s/%s failed: %s", file.profileId, file.id, error.msg);
            tasks.finish(
                file,
                "failed",
                nowIso(),
                session.sessionId,
                "",
                Json.object(file.task).text("reasoning_mode"),
                "",
                error.msg,
            );
        }
    }

    private SessionKey resolveSession(ScheduledTaskFile file, string startedAt)
    {
        auto task = Json.object(file.task);
        auto target = task.object("target");
        auto kind = target.text("kind");
        if (kind == "originating_session") {
            auto session = SessionKey(file.profileId, target.text("session_id"));
            history.requireSession(session);
            return session;
        }
        if (kind == "new_session") return history.startProfileSession(
            file.profileId,
            startedAt,
            "scheduled_task",
            "en",
            parseReasoningMode(task.text("reasoning_mode")),
            target.text("model"),
        );
        auto sessionId = presence.activeSessionId(file.profileId, startedAt);
        enforce(sessionId.length, "No eligible active chat is available");
        auto session = SessionKey(file.profileId, sessionId);
        history.requireSession(session);
        return session;
    }
}
