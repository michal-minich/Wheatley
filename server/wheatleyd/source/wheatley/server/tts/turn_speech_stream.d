module wheatley.server.tts.turn_speech_stream;

import core.sync.mutex : Mutex;
import core.time : MonoTime, dur;
import std.exception : enforce;
import std.string : strip;

import vibe.core.core : sleep;
import wheatley.common.api.session : SessionKey;

import wheatley.common.api.tts : TtsResponse, ttsAudioUrl;
import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonStringField;
import wheatley.server.history.files : RuntimeFiles;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.tts.on_demand : OnDemandTts;
import wheatley.server.tts.segment_buffer : TtsSegmentBuffer;
import wheatley.server.tts.turn_speech_registry :
    TurnSpeechRegistry,
    TurnSpeechSource;

final class TurnSpeechStream
{
    private enum sourceWaitSeconds = 120;

    private HistoryStore store;
    private RuntimeFiles files;
    private OnDemandTts tts;
    private TurnSpeechRegistry turns;
    private SpeechStopRegistry stops;

    this(
        HistoryStore store,
        RuntimeFiles files,
        OnDemandTts tts,
        TurnSpeechRegistry turns,
    )
    {
        this.store = store;
        this.files = files;
        this.tts = tts;
        this.turns = turns;
        this.stops = new SpeechStopRegistry;
    }

    void stop(SessionKey session, string speechId)
    {
        stops.stop(session, speechId);
    }

    void stream(
        SessionKey session,
        string turnId,
        string speechId,
        string sourceKind,
        string itemId,
        bool includeReasoningStatus,
        bool startAfterExisting,
        void delegate(string eventName, string dataJson) emit,
    )
    {
        stops.begin(session, speechId);
        scope(exit) stops.finish(speechId);
        auto source = waitForSource(session, turnId, speechId, sourceKind, itemId);
        if (source is null) {
            emit("done", speechDoneJson(true));
            return;
        }

        auto buffer = TtsSegmentBuffer();
        auto initialSnapshot = source.snapshot();
        size_t consumedBytes = startAfterExisting ? initialSnapshot.text.length : 0;
        long segmentIndex;
        bool statusConsumed = startAfterExisting && initialSnapshot.status.strip.length > 0;
        while (!stops.stopped(speechId)) {
            auto snapshot = source.snapshot();
            if (
                includeReasoningStatus
                && !statusConsumed
                && snapshot.status.strip.length
            ) {
                statusConsumed = true;
                if (!emitSegments(
                    session.profileId,
                    speechId,
                    snapshot.language,
                    [snapshot.status.strip],
                    segmentIndex,
                    emit,
                )) {
                    emit("done", speechDoneJson(true));
                    return;
                }
            }
            if (snapshot.text.length > consumedBytes) {
                auto delta = snapshot.text[consumedBytes .. $];
                consumedBytes = snapshot.text.length;
                if (!emitSegments(
                    session.profileId,
                    speechId,
                    snapshot.language,
                    buffer.feed(delta),
                    segmentIndex,
                    emit,
                )) {
                    emit("done", speechDoneJson(true));
                    return;
                }
            }
            if (snapshot.complete) {
                if (!emitSegments(
                    session.profileId,
                    speechId,
                    snapshot.language,
                    buffer.finish(),
                    segmentIndex,
                    emit,
                )) {
                    emit("done", speechDoneJson(true));
                    return;
                }
                emit("done", speechDoneJson(false));
                return;
            }
            sleep(dur!"msecs"(40));
        }
        emit("done", speechDoneJson(true));
    }

    private TurnSpeechSource waitForSource(
        SessionKey session,
        string turnId,
        string speechId,
        string sourceKind,
        string itemId,
    )
    {
        auto started = MonoTime.currTime;
        auto requestedTurnId = turnId;
        while (!stops.stopped(speechId)) {
            auto active = turns.find(session, turnId);
            if (active !is null) {
                if (!itemId.length) return active.source(sourceKind);
                auto itemSource = active.findItemSource(sourceKind, itemId);
                if (itemSource !is null) return itemSource;
                sleep(dur!"msecs"(40));
                continue;
            }

            auto stored = store.findTurn(session, turnId);
            if (!stored.id.length && turnId == requestedTurnId)
                stored = store.findTurnBySubmission(session, requestedTurnId);
            if (stored.id.length && stored.id != turnId) {
                turnId = stored.id;
                continue;
            }
            if (stored.id.length && stored.status.length) {
                auto text = itemId.length
                    ? store.turnPresentationItemText(
                        session,
                        turnId,
                        itemId,
                        sourceKind == "reasoning" ? "reasoning" : "assistant",
                    )
                    : stored.assistantText.strip;
                if (text.length) {
                    auto source = new TurnSpeechSource(session, stored.language);
                    source.feed(text);
                    source.finish();
                    return source;
                }
            }
            if ((MonoTime.currTime - started).total!"seconds" >= sourceWaitSeconds) {
                enforce(false, "Assistant turn is not available for speech");
            }
            sleep(dur!"msecs"(40));
        }
        return null;
    }

    private bool emitSegments(
        string profileId,
        string speechId,
        string language,
        string[] segments,
        ref long segmentIndex,
        void delegate(string eventName, string dataJson) emit,
    )
    {
        foreach (segment; segments) {
            if (stops.stopped(speechId)) return false;
            auto result = tts.synthesize(profileId, segment, language);
            if (stops.stopped(speechId)) {
                files.removeGeneratedTts(profileId, result.artifactId);
                return false;
            }
            emit("segment", speechSegmentJson(segmentIndex, result));
            segmentIndex++;
        }
        return true;
    }
}

private final class SpeechStopRegistry
{
    private struct SpeechState
    {
        SessionKey session;
        bool stopped;
    }

    private Mutex lock;
    private SpeechState[string] states;

    this()
    {
        lock = new Mutex;
    }

    void begin(SessionKey session, string speechId)
    {
        lock.lock();
        scope(exit) lock.unlock();
        enforce(speechId !in states, "Speech stream is already active: " ~ speechId);
        states[speechId] = SpeechState(session, false);
    }

    void stop(SessionKey session, string speechId)
    {
        lock.lock();
        scope(exit) lock.unlock();
        auto state = speechId in states;
        if (state is null) return;
        enforce(state.session == session, "Speech session mismatch");
        state.stopped = true;
    }

    bool stopped(string speechId)
    {
        lock.lock();
        scope(exit) lock.unlock();
        auto state = speechId in states;
        return state !is null && state.stopped;
    }

    void finish(string speechId)
    {
        lock.lock();
        scope(exit) lock.unlock();
        states.remove(speechId);
    }
}

unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    import wheatley.common.api.reasoning : ReasoningMode;
    import wheatley.server.config.app_config_store : AppConfigStore;
    import wheatley.server.history.rows.text_turn_record : TextTurnRecord;

    auto root = buildPath(tempDir(), "wheatley-turn-speech-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto store = new HistoryStore(
        profilesRoot,
        new AppConfigStore(configPath),
        root,
    );
    auto startedAt = "2026-08-06T08:04:14.629642Z";
    auto session = store.startProfileSession("tester", startedAt, "test", "en");
    auto submissionId = "web-audio-live-43002540-157f-45e4-ba96-c66195e78636";

    TextTurnRecord record;
    record.turnId = submissionId;
    record.profileId = session.profileId;
    record.sessionId = session.sessionId;
    record.deviceId = "web";
    record.source = "audio_live";
    record.status = "pending";
    record.startedAt = startedAt;
    record.modelName = "pi:test";
    record.language = "en";
    record.userText = "Hello";
    record.reasoningMode = ReasoningMode.off;
    record.submissionId = submissionId;
    record.submissionJson = `{"device_id":"web","user_text":"Hello"}`;
    auto canonicalTurnId = store.beginTextTurn(record);
    record.turnId = canonicalTurnId;
    record.status = "completed";
    record.completedAt = "2026-08-06T08:04:15.629642Z";
    record.assistantText = "Stored answer.";
    store.saveTextTurn(record);

    auto turns = new TurnSpeechRegistry;
    auto active = turns.begin(session, canonicalTurnId, "en");
    active.feedAnswer("assistant:0:1", "Live answer.");
    auto speech = new TurnSpeechStream(store, null, null, turns);
    auto source = speech.waitForSource(
        session,
        submissionId,
        "speech-1",
        "answer",
        "",
    );

    assert(source is active.source("answer"));
}

private string speechSegmentJson(long index, TtsResponse result)
{
    return jsonObject([
        jsonLongField("index", index),
        jsonStringField("audio_url", ttsAudioUrl(result)),
        jsonStringField("media_type", result.mediaType),
    ]);
}

private string speechDoneJson(bool stopped)
{
    return jsonObject([jsonBoolField("stopped", stopped)]);
}
