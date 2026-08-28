module wheatley.server.conversation.agent_runtime;

import core.time : MonoTime;

import wheatley.common.api.reasoning : ReasoningMode;
import wheatley.common.api.session : SessionKey;
import wheatley.server.conversation.event_stream : ConversationEventStream;
import wheatley.server.tools.types : ExecutedTool;
import wheatley.server.turns.text.profile_runtime_settings : ProfileRuntimeSettings;

/** Semantic content used by device-local narration while an agent is running. */
struct AgentContentEvent
{
    string kind;
    string phase;
    string itemId;
    string text;
}

struct AgentUserImage
{
    string path;
    string mediaType;
}

alias AgentContentEventSink = void delegate(AgentContentEvent event);

/** Complete accepted input and frozen policy for one Agent Runtime invocation. */
struct AgentTurnInput
{
    SessionKey session;
    string turnId;
    string userText;
    string clientId;
    string startedAt;
    ProfileRuntimeSettings settings;
    ReasoningMode reasoningMode;
    bool loadMemory;
    ConversationEventStream events;
    AgentContentEventSink contentChanged;
    bool delegate() stopped;
    bool hasUserImage;
    AgentUserImage userImage;
    ExecutedTool[] prefixTools;
    string privatePrompt;
}

struct AgentSteerInput
{
    SessionKey session;
    string turnId;
    string userText;
    string clientId;
    string modelName;
    ReasoningMode reasoningMode;
    ConversationEventStream events;
    AgentContentEventSink contentChanged;
    void delegate() admitted;
}

struct AgentSteeredTurnResult
{
    string turnId;
    string assistantText;
    long toolCount;
    ExecutedTool[] tools;
    string metricsJson;
    string reasoningMetricsJson;
    bool hasFirstAssistantDelta;
    MonoTime firstAssistantDeltaMono;
    bool hasLatestAssistantStart;
    MonoTime latestAssistantStartMono;
    ConversationEventStream events;
}

struct AgentTurnResult
{
    string assistantText;
    long toolCount;
    ExecutedTool[] tools;
    string metricsJson;
    string reasoningMetricsJson;
    bool hasFirstAssistantDelta;
    MonoTime firstAssistantDeltaMono;
    bool hasProcessEnd;
    MonoTime processEndMono;
    bool hasLatestAssistantStart;
    MonoTime latestAssistantStartMono;
    AgentSteeredTurnResult[] steeredTurns;
}

class AgentRuntimeFailure : Exception
{
    string assistantText;
    ExecutedTool[] tools;
    long toolCount;
    string metricsJson;
    string reasoningMetricsJson;
    string errorsJson;
    bool hasExitStatus;
    int exitStatus;
    bool hasFirstAssistantDelta;
    MonoTime firstAssistantDeltaMono;
    bool hasProcessEnd;
    MonoTime processEndMono;
    bool hasLatestAssistantStart;
    MonoTime latestAssistantStartMono;
    AgentSteeredTurnResult[] steeredTurns;
    bool hasProcessStart;

    this(
        string message,
        string assistantText,
        ExecutedTool[] tools,
        long toolCount,
        string metricsJson,
        string reasoningMetricsJson,
        string errorsJson,
        bool hasExitStatus,
        int exitStatus,
        bool hasFirstAssistantDelta,
        MonoTime firstAssistantDeltaMono,
        bool hasProcessEnd,
        MonoTime processEndMono,
        bool hasLatestAssistantStart,
        MonoTime latestAssistantStartMono,
        AgentSteeredTurnResult[] steeredTurns = [],
        bool hasProcessStart = false,
    )
    {
        super(message);
        this.assistantText = assistantText;
        this.tools = tools;
        this.toolCount = toolCount;
        this.metricsJson = metricsJson;
        this.reasoningMetricsJson = reasoningMetricsJson;
        this.errorsJson = errorsJson;
        this.hasExitStatus = hasExitStatus;
        this.exitStatus = exitStatus;
        this.hasFirstAssistantDelta = hasFirstAssistantDelta;
        this.firstAssistantDeltaMono = firstAssistantDeltaMono;
        this.hasProcessEnd = hasProcessEnd;
        this.processEndMono = processEndMono;
        this.hasLatestAssistantStart = hasLatestAssistantStart;
        this.latestAssistantStartMono = latestAssistantStartMono;
        this.steeredTurns = steeredTurns;
        this.hasProcessStart = hasProcessStart;
    }
}

/** Placeable agent capability used by Conversation Runtime. */
interface AgentRuntime
{
    /** True when the external agent command can be launched now. */
    bool available(ProfileRuntimeSettings settings);
    AgentTurnResult run(AgentTurnInput input);
    bool steer(AgentSteerInput input);
    string compact(SessionKey session, ProfileRuntimeSettings settings);
    void stop(SessionKey session, string turnId);
    void recycle(SessionKey session);
    void shutdown();
}
