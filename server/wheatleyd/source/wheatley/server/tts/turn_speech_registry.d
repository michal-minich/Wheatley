module wheatley.server.tts.turn_speech_registry;

import core.sync.mutex : Mutex;
import std.exception : enforce;

import wheatley.common.choice : requireChoice;
import wheatley.common.api.session : SessionKey;

struct TurnSpeechSnapshot
{
    string text;
    string language;
    bool complete;
    string status;
}

final class TurnSpeechSource
{
    private Mutex lock;
    private SessionKey sessionValue;
    private string text;
    private string language;
    private bool complete;
    private string status;

    this(SessionKey session, string language)
    {
        this.lock = new Mutex;
        this.sessionValue = session;
        this.language = language;
    }

    SessionKey session()
    {
        return sessionValue;
    }

    void setLanguage(string value)
    {
        if (!value.length) return;
        lock.lock();
        scope(exit) lock.unlock();
        language = value;
    }

    void feed(string value)
    {
        if (!value.length) return;
        lock.lock();
        scope(exit) lock.unlock();
        enforce(!complete, "Cannot feed a completed speech turn");
        text ~= value;
    }

    void markStatus(string value)
    {
        if (!value.length) return;
        lock.lock();
        scope(exit) lock.unlock();
        if (!status.length) status = value;
    }

    void finish()
    {
        lock.lock();
        scope(exit) lock.unlock();
        complete = true;
    }

    TurnSpeechSnapshot snapshot()
    {
        lock.lock();
        scope(exit) lock.unlock();
        return TurnSpeechSnapshot(text, language, complete, status);
    }
}

final class TurnSpeechTurn
{
    private TurnSpeechSource answerSource;
    private TurnSpeechSource reasoningSource;
    private Mutex itemLock;
    private TurnSpeechSource[string] itemSources;

    this(SessionKey session, string language)
    {
        answerSource = new TurnSpeechSource(session, language);
        reasoningSource = new TurnSpeechSource(session, language);
        itemLock = new Mutex;
    }

    SessionKey session()
    {
        return answerSource.session;
    }

    TurnSpeechSource source(string kind)
    {
        return requireChoice!("answer", "reasoning")(kind) == "reasoning"
            ? reasoningSource
            : answerSource;
    }

    void setLanguage(string value)
    {
        answerSource.setLanguage(value);
        reasoningSource.setLanguage(value);
        itemLock.lock();
        TurnSpeechSource[] items;
        foreach (source; itemSources) items ~= source;
        itemLock.unlock();
        foreach (source; items) source.setLanguage(value);
    }

    void feedAnswer(string itemId, string value)
    {
        answerSource.feed(value);
        itemSource("answer", itemId).feed(value);
    }

    /// Publishes text for an independently playable visual item without adding
    /// it to the automatically spoken aggregate answer.
    void feedAnswerItem(string itemId, string value)
    {
        auto item = itemSource("answer", itemId);
        item.feed(value);
        item.finish();
    }

    void feedProgress(string value)
    {
        answerSource.feed(value ~ " ");
    }

    unittest
    {
        auto turn = new TurnSpeechTurn(SessionKey("wheatley", "session"), "en");
        turn.feedProgress("I'm searching.");
        turn.feedAnswer("answer-1", "The result is ready.");
        turn.feedAnswerItem("image-1", "A mountain observatory.");
        assert(turn.source("answer").snapshot().text == "I'm searching. The result is ready.");
        assert(turn.findItemSource("answer", "image-1").snapshot().text
            == "A mountain observatory.");
    }

    void feedReasoning(string itemId, string value, string status)
    {
        answerSource.markStatus(status);
        reasoningSource.feed(value);
        itemSource("reasoning", itemId).feed(value);
    }

    void finishItem(string kind, string itemId)
    {
        auto source = findItemSource(kind, itemId);
        if (source !is null) source.finish();
    }

    TurnSpeechSource findItemSource(string kind, string itemId)
    {
        auto key = itemKey(kind, itemId);
        itemLock.lock();
        scope(exit) itemLock.unlock();
        auto source = key in itemSources;
        return source is null ? null : *source;
    }

    void finish()
    {
        answerSource.finish();
        reasoningSource.finish();
        itemLock.lock();
        TurnSpeechSource[] items;
        foreach (source; itemSources) items ~= source;
        itemLock.unlock();
        foreach (source; items) source.finish();
    }

    private TurnSpeechSource itemSource(string kind, string itemId)
    {
        auto key = itemKey(kind, itemId);
        itemLock.lock();
        scope(exit) itemLock.unlock();
        auto existing = key in itemSources;
        if (existing !is null) return *existing;
        auto source = new TurnSpeechSource(session, answerSource.snapshot().language);
        itemSources[key] = source;
        return source;
    }

    private string itemKey(string kind, string itemId)
    {
        requireChoice!("answer", "reasoning")(kind);
        enforce(itemId.length, "Speech item ID is required");
        return kind ~ ":" ~ itemId;
    }
}

final class TurnSpeechRegistry
{
    private Mutex lock;
    private TurnSpeechTurn[string] sources;

    this()
    {
        lock = new Mutex;
    }

    TurnSpeechTurn begin(SessionKey session, string turnId, string language)
    {
        auto source = new TurnSpeechTurn(session, language);
        lock.lock();
        scope(exit) lock.unlock();
        enforce(turnId !in sources, "Speech turn is already active: " ~ turnId);
        sources[turnId] = source;
        return source;
    }

    TurnSpeechTurn find(SessionKey session, string turnId)
    {
        lock.lock();
        scope(exit) lock.unlock();
        auto source = turnId in sources;
        if (source is null) return null;
        enforce((*source).session == session, "Speech turn session mismatch");
        return *source;
    }

    void finish(string turnId)
    {
        lock.lock();
        auto source = turnId in sources;
        if (source is null) {
            lock.unlock();
            return;
        }
        auto active = *source;
        sources.remove(turnId);
        lock.unlock();
        active.finish();
    }
}
