module wheatley.server.history.store.conversation_submissions;

unittest
{
    import std.exception : assertThrown;
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.string : splitLines;
    import std.uuid : randomUUID;

    import wheatley.common.api.reasoning : ReasoningMode;
    import wheatley.common.conversation.events : ConversationEvent, ConversationToolEvent;
    import wheatley.common.json.read : Json;
    import wheatley.server.config.app_config_store : AppConfigStore;
    import wheatley.server.conversation.event_stream : ConversationEventStream;
    import wheatley.server.history.rows.text_turn_record : TextTurnRecord;
    import wheatley.server.history.store : HistoryStore;

    auto root = buildPath(
        tempDir(),
        "wheatley-conversation-submission-" ~ randomUUID().toString(),
    );
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto profilesRoot = buildPath(root, "profiles");
    mkdirRecurse(buildPath(profilesRoot, "tester"));
    auto configPath = buildPath(root, "config.json");
    write(configPath, "{}");
    auto appConfig = new AppConfigStore(configPath);
    auto store = new HistoryStore(profilesRoot, appConfig, root);
    auto startedAt = "2026-08-05T12:00:00.000001Z";
    auto session = store.startProfileSession("tester", startedAt, "test", "en");

    TextTurnRecord record;
    record.turnId = "device-submission-1";
    record.profileId = session.profileId;
    record.sessionId = session.sessionId;
    record.deviceId = "device";
    record.source = "api_text";
    record.status = "pending";
    record.startedAt = startedAt;
    record.modelName = "pi:test";
    record.language = "en";
    record.userText = "hello";
    record.reasoningMode = ReasoningMode.off;
    record.submissionId = "device-submission-1";
    record.submissionJson = `{"device_id":"device","user_text":"hello"}`;
    auto turnId = store.beginTextTurn(record);
    auto executionId = store.claimConversationTurn(session, turnId);
    assert(executionId.length);

    ConversationEvent[] delivered;
    auto events = new ConversationEventStream(
        session,
        turnId,
        (event) {
            store.appendConversationEvent(event);
            delivered ~= event;
        },
    );
    events.status("started", "Started");
    events.tool(ConversationToolEvent(
        "start", "model-context", "model_context", -1, "succeeded",
        "tester", "Model context", false, "", "{}",
    ));
    events.fail("ambiguous", "Interrupted");
    assert(delivered.length == 3);

    auto presentation = readText(buildPath(
        profilesRoot,
        "tester",
        "sessions",
        session.sessionId,
        "presentation.jsonl",
    )).splitLines;
    assert(Json.parse(presentation[1]).text("kind") == "tool");
    assert(Json.parse(presentation[2]).text("kind") == "user");

    auto reopened = new HistoryStore(profilesRoot, appConfig, root);
    auto stored = reopened.findTurnBySubmission(session, record.submissionId);
    assert(stored.id == turnId);
    assert(stored.submissionJson.length);
    auto replay = reopened.conversationEvents(session, turnId);
    assert(replay.length == 3);
    assert(replay[0].sequence == 1);
    assert(replay[1].sequence == 2);
    assert(replay[2].sequence == 3);

    reopened.failInterruptedConversationTurn(
        session,
        turnId,
        "2026-08-05T12:01:00.000001Z",
        "Interrupted",
    );
    record.turnId = turnId;
    record.executionId = executionId;
    record.status = "completed";
    assertThrown(reopened.saveTextTurn(record));
}
