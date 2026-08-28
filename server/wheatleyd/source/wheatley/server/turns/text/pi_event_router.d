module wheatley.server.turns.text.pi_event_router;

import core.time : MonoTime;
import core.sync.mutex : Mutex;

import std.array : Appender, appender;
import std.json : JSONType, JSONValue, parseJSON;

import wheatley.common.json.read : Json;
import wheatley.server.conversation.agent_runtime : AgentContentEvent;
import wheatley.server.conversation.event_stream : ConversationEventStream;
import wheatley.server.tools.types : ExecutedTool;
import wheatley.server.turns.text.pi_compaction : PiCompactionSink;
import wheatley.server.turns.text.pi_event_sink : PiWorkerEventSink;
import wheatley.server.turns.text.pi_events : PiEventCollector;
import wheatley.server.turns.text.profile_runtime_settings : ProfileRuntimeSettings;

struct PiEventTarget
{
    string turnId;
    string userText;
    ConversationEventStream eventStream;
    void delegate(ExecutedTool[] tools) toolsChanged;
    void delegate(AgentContentEvent event) contentChanged;
    PiCompactionSink compactionChanged;
    void delegate() activated;
    ExecutedTool[] prefixTools;
}

struct PiEventSegment
{
    PiEventTarget target;
    PiEventCollector collector;
    MonoTime startedMono;
    MonoTime endedMono;
}

/** Routes one Pi agent run across the durable user-message boundaries that Pi
    itself emits for queued steering.  No timer or client arrival guess decides
    when a new segment begins. */
final class PiEventRouter : PiWorkerEventSink
{
    private string profileId;
    private ProfileRuntimeSettings settings;
    private Mutex mutex;
    private PiEventTarget activeTarget;
    private PiEventCollector activeCollector;
    private MonoTime activeStartedMono;
    private PiEventTarget[] queued;
    private PiEventSegment[] completed;
    private string initialTurnId;
    private bool initialUserSeen;
    private Appender!string rawEvents;
    private bool finished;
    private bool undeliveredSteers;

    this(string profileId, ProfileRuntimeSettings settings, PiEventTarget initial)
    {
        this.profileId = profileId;
        this.settings = settings;
        this.mutex = new Mutex;
        this.activeTarget = initial;
        this.initialTurnId = initial.turnId;
        this.activeCollector = collectorFor(initial);
        this.activeStartedMono = MonoTime.currTime;
        this.rawEvents = appender!string;
    }

    void queueSteer(PiEventTarget target)
    {
        synchronized (mutex) queued ~= target;
    }

    bool removeQueued(string turnId)
    {
        synchronized (mutex) {
            foreach (index, target; queued) {
                if (target.turnId != turnId) continue;
                queued = queued[0 .. index] ~ queued[index + 1 .. $];
                return true;
            }
        }
        return false;
    }

    void handleLine(string line)
    {
        if (line.length) {
            rawEvents.put(line);
            rawEvents.put("\n");
        }
        if (isUserMessageStart(line)) {
            if (!initialUserSeen) {
                initialUserSeen = true;
            } else {
                PiEventTarget next;
                synchronized (mutex) {
                    if (queued.length) {
                        next = queued[0];
                        queued = queued[1 .. $];
                    }
                }
                if (next.turnId.length) {
                    auto boundaryMono = MonoTime.currTime;
                    activeCollector.finish();
                    completed ~= PiEventSegment(
                        activeTarget,
                        activeCollector,
                        activeStartedMono,
                        boundaryMono,
                    );
                    activeTarget = next;
                    activeCollector = collectorFor(next);
                    activeStartedMono = boundaryMono;
                    if (next.activated !is null) next.activated();
                }
            }
        }
        activeCollector.handleLine(line);
    }

    void finish()
    {
        if (finished) return;
        finished = true;
        auto finishedMono = MonoTime.currTime;
        activeCollector.finish();
        completed ~= PiEventSegment(
            activeTarget,
            activeCollector,
            activeStartedMono,
            finishedMono,
        );
        PiEventTarget[] remaining;
        synchronized (mutex) {
            remaining = queued;
            queued = [];
        }
        undeliveredSteers = remaining.length > 0;
    }

    bool hasUndeliveredSteers() const
    {
        return undeliveredSteers;
    }

    PiEventSegment initialSegment()
    {
        foreach (segment; completed)
            if (segment.target.turnId == initialTurnId) return segment;
        return PiEventSegment(
            activeTarget,
            activeCollector,
            activeStartedMono,
            MonoTime.currTime,
        );
    }

    PiEventSegment[] steeringSegments()
    {
        PiEventSegment[] result;
        foreach (segment; completed)
            if (segment.target.turnId != initialTurnId) result ~= segment;
        return result;
    }

    string rawJsonl()
    {
        return rawEvents.data;
    }

    private PiEventCollector collectorFor(PiEventTarget target)
    {
        return new PiEventCollector(
            profileId,
            settings,
            target.eventStream,
            target.toolsChanged,
            target.contentChanged,
            target.compactionChanged,
            target.prefixTools,
        );
    }
}

private bool isUserMessageStart(string line)
{
    JSONValue value;
    try value = parseJSON(line);
    catch (Exception) return false;
    if (value.type != JSONType.object) return false;
    auto event = Json.object(value);
    if (event.opt.textOrEmpty("type") != "message_start") return false;
    auto message = event.opt.object("message");
    return !message.isNull && message.get.opt.textOrEmpty("role") == "user";
}

unittest
{
    assert(isUserMessageStart(
        `{"type":"message_start","message":{"role":"user","content":[]}}`,
    ));
    assert(!isUserMessageStart(
        `{"type":"message_start","message":{"role":"assistant","content":[]}}`,
    ));
    assert(!isUserMessageStart("not json"));
}

unittest
{
    ProfileRuntimeSettings settings;
    auto router = new PiEventRouter(
        "tester",
        settings,
        PiEventTarget("turn-1", "first"),
    );
    router.queueSteer(PiEventTarget("turn-2", "second"));
    router.queueSteer(PiEventTarget("turn-3", "third"));
    router.handleLine(
        `{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"first"}]}}`,
    );
    router.handleLine(
        `{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"second"}]}}`,
    );
    router.handleLine(
        `{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"third"}]}}`,
    );
    router.finish();
    assert(router.initialSegment.target.turnId == "turn-1");
    auto steering = router.steeringSegments;
    assert(steering.length == 2);
    assert(steering[0].target.turnId == "turn-2");
    assert(steering[1].target.turnId == "turn-3");
}

unittest
{
    ProfileRuntimeSettings settings;
    long activations;
    auto router = new PiEventRouter(
        "tester",
        settings,
        PiEventTarget("turn-1", "first"),
    );
    router.queueSteer(PiEventTarget(
        "turn-2",
        "second",
        null,
        null,
        null,
        null,
        () { activations++; },
    ));
    router.handleLine(
        `{"type":"message_start","message":{"role":"user","content":[]}}`,
    );
    assert(activations == 0);
    router.handleLine(
        `{"type":"message_start","message":{"role":"user","content":[]}}`,
    );
    assert(activations == 1);
    router.finish();
    assert(!router.hasUndeliveredSteers);
}

unittest
{
    ProfileRuntimeSettings settings;
    auto router = new PiEventRouter(
        "tester",
        settings,
        PiEventTarget("turn-1", "first"),
    );
    router.queueSteer(PiEventTarget("turn-2", "second"));
    router.finish();
    assert(router.hasUndeliveredSteers);
    assert(router.steeringSegments.length == 0);
}
