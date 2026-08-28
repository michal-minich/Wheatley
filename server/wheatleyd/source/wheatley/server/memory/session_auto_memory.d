module wheatley.server.memory.session_auto_memory;

import core.time : MonoTime;

import std.algorithm.searching : canFind, startsWith;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, readText;
import std.path : baseName, buildPath;
import std.string : replace, splitLines, strip;

import vibe.core.path : NativePath;
import vibe.core.process : Config, Redirect;
import vibe.stream.operations : readLine;

import wheatley.server.history.documents.profile_auto_memory_types :
    SessionAutoMemoryFailure,
    SessionAutoMemoryPlan,
    SessionAutoMemorySave,
    SessionAutoMemoryTurn;
import wheatley.common.api.session : SessionKey;
import wheatley.common.api.reasoning : piThinkingLevel;
import wheatley.common.runtime.process_runner : pipeLocalProcess;
import wheatley.server.history.profiles.prompt_context_types : ProfilePromptDocuments;
import wheatley.server.history.store : HistoryStore;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.server.turns.text.pi_events : PiEventCollector;
import wheatley.server.turns.text.llm_metrics : llmMetricsJson, utf8CharCount;
import wheatley.server.turns.text.pi_runtime :
    limitPiText,
    resolvePiExecutable,
    safeId;
import wheatley.server.turns.text.profile_runtime_settings : ProfileRuntimeSettings;
import wheatley.server.turns.text.pi_run_gate : PiRunGate;

struct SessionAutoMemoryResult
{
    long processedSessions;
    long processedMessages;
    bool failed;
    string errorMessage;
}

SessionAutoMemoryResult runSessionAutoMemory(
    HistoryStore store,
    SessionKey session,
    string resourcesRoot,
    ProfileRuntimeSettings settings,
    PiRunGate piRuns,
    void delegate(string kind, string message) emitSystem,
)
{
    auto plan = planSessionAutoMemory(store, session, settings);
    return runPlannedSessionAutoMemory(store, session, resourcesRoot, plan, settings, piRuns, emitSystem, true);
}

SessionAutoMemoryPlan planSessionAutoMemory(
    HistoryStore store,
    SessionKey session,
    ProfileRuntimeSettings settings,
)
{
    SessionAutoMemoryPlan plan;
    if (!settings.memoryAutoEnabled) return plan;
    plan.enabled = true;
    try {
        plan.processTodoAfterRecovery = store.sessionAutoMemoryRecoveryPending(session);
        plan.batchMarkdown = store.prepareSessionAutoMemoryBatch(
            session,
            settings.memoryAutoTriggerBytes,
            settings.memoryAutoMaxPendingHours,
            nowIso(),
        );
    } catch (Exception error) {
        plan.failed = true;
        plan.errorMessage = error.msg;
        return plan;
    }

    auto counts = batchCounts(plan.batchMarkdown);
    plan.processedSessions = counts.sessions;
    plan.processedMessages = counts.messages;
    return plan;
}

bool hasSessionAutoMemoryWork(SessionAutoMemoryPlan plan)
{
    return plan.enabled && !plan.failed && plan.batchMarkdown.strip.length > 0;
}

SessionAutoMemoryResult runPlannedSessionAutoMemory(
    HistoryStore store,
    SessionKey session,
    string resourcesRoot,
    SessionAutoMemoryPlan plan,
    ProfileRuntimeSettings settings,
    PiRunGate piRuns,
    void delegate(string kind, string message) emitSystem,
    bool emitStart,
)
{
    SessionAutoMemoryResult result;
    scope(exit) snapshotSessionAutoMemoryQuietly(store, session);
    if (!plan.enabled) return result;
    if (plan.failed) {
        result.failed = true;
        result.errorMessage = plan.errorMessage;
        emitMemoryFailure(emitSystem, settings);
        return result;
    }

    auto batch = plan.batchMarkdown;
    auto processTodoAfterSuccess = plan.processTodoAfterRecovery;
    bool emittedStart;
    while (batch.strip.length) {
        auto counts = batchCounts(batch);
        result.processedSessions += counts.sessions;
        result.processedMessages += counts.messages;
        if (emitStart && !emittedStart) emitMemoryStart(emitSystem, settings);
        emittedStart = true;

        SessionAutoMemoryTurn turn;
        string requestMarkdown;
        string failureLlmMetrics;
        auto turnStartedAt = nowIso();
        try {
            turn = store.createSessionAutoMemoryTurn(session, turnStartedAt);
            auto documents = store.profilePromptDocuments(session.profileId);
            auto templateText = store.runtimePromptTemplate("memory_rules");
            requestMarkdown = memoryRequestMarkdown(
                templateText,
                session.profileId,
                memoryMessageDate(nowIso()),
                documents,
                batch,
            );
            store.saveSessionAutoMemoryRequest(
                session.profileId,
                turn,
                requestMarkdown,
                counts.sessions,
                counts.messages,
                utf8CharCount(requestMarkdown),
            );
            auto memoryRun = runPiMemorySession(
                store,
                session.profileId,
                turn,
                requestMarkdown,
                settings,
                piRuns,
            );
            failureLlmMetrics = memoryRun.llmMetricsJson;
            auto sanitizedMemory = sanitizeAutoMemoryMarkdown(memoryRun.outputMarkdown);
            validateAutoMemoryMarkdown(sanitizedMemory);

            store.saveSessionAutoMemorySuccess(session.profileId, SessionAutoMemorySave(
                turn,
                requestMarkdown,
                normalizeMarkdown(sanitizedMemory),
                turn.turnRoot,
                session.sessionId,
                counts.sessions,
                counts.messages,
                utf8CharCount(requestMarkdown),
                utf8CharCount(sanitizedMemory),
                memoryRun.llmMetricsJson,
                nowIso(),
            ));
            emitMemoryDone(emitSystem, settings);
            batch = processTodoAfterSuccess
                ? store.prepareSessionAutoMemoryBatch(
                    session,
                    settings.memoryAutoTriggerBytes,
                    settings.memoryAutoMaxPendingHours,
                    nowIso(),
                )
                : "";
            processTodoAfterSuccess = false;
        } catch (Exception error) {
            result.failed = true;
            result.errorMessage = error.msg;
            auto memoryError = cast(PiMemorySessionFailure) error;
            if (memoryError !is null) failureLlmMetrics = memoryError.llmMetricsJson;
            if (turn.turnRoot.length) {
                store.saveSessionAutoMemoryFailure(session.profileId, SessionAutoMemoryFailure(
                    turn,
                    requestMarkdown,
                    turn.turnRoot,
                    error.msg,
                    counts.sessions,
                    counts.messages,
                    utf8CharCount(requestMarkdown),
                    failureLlmMetrics,
                    nowIso(),
                ));
            }
            emitMemoryFailure(emitSystem, settings);
            break;
        }
    }

    return result;
}

private struct PiMemorySessionResult
{
    string outputMarkdown;
    string llmMetricsJson;
}

private void snapshotSessionAutoMemoryQuietly(HistoryStore store, SessionKey session) nothrow
{
    try store.snapshotSessionAutoMemory(session);
    catch (Throwable) {}
}

private class PiMemorySessionFailure : Exception
{
    string llmMetricsJson;

    this(string message, string llmMetricsJson)
    {
        super(message);
        this.llmMetricsJson = llmMetricsJson;
    }
}

private PiMemorySessionResult runPiMemorySession(
    HistoryStore store,
    string profileId,
    SessionAutoMemoryTurn turn,
    string requestMarkdown,
    ProfileRuntimeSettings settings,
    PiRunGate piRuns,
)
{
    auto workingRoot = store.profileFilesRoot(profileId);
    auto events = new PiEventCollector(profileId, settings);
    int exitStatus;
    bool hasProcessStart;
    MonoTime processStarted;
    MonoTime processEnded;

    try {
        piRuns.lock();
        scope(exit) piRuns.unlock();
        processStarted = MonoTime.currTime;
        hasProcessStart = true;
        auto pipes = pipeLocalProcess(
            piMemoryCommand(profileId, turn, settings),
            Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout,
            ["WHEATLEY_PROVIDER_REQUEST_JSON": settings.providerRequestOverridesJson],
            Config.none,
            NativePath(workingRoot),
        );

        pipes.stdin.write(requestMarkdown);
        pipes.stdin.close();

        while (!pipes.stdout.empty) {
            auto line = cast(string) pipes.stdout.readLine(1024 * 1024, "\n");
            if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
            events.handleLine(line.strip);
        }
        exitStatus = pipes.process.wait();
        processEnded = MonoTime.currTime;
    } catch (Exception error) {
        if (hasProcessStart) processEnded = MonoTime.currTime;
        throw new PiMemorySessionFailure(
            "Pi memory session failed: " ~ error.msg,
            llmMetricsJson(
                requestMarkdown,
                events.assistantText.strip,
                events,
                hasProcessStart,
                processStarted,
                processEnded,
            ),
        );
    }

    auto output = events.assistantText.strip;
    auto metrics = llmMetricsJson(requestMarkdown, output, events, hasProcessStart, processStarted, processEnded);
    if (exitStatus != 0) {
        throw new PiMemorySessionFailure(
            piMemoryFailureMessage(exitStatus, events.rawJsonl),
            metrics,
        );
    }

    if (!output.length) {
        throw new PiMemorySessionFailure(
            "Pi memory session completed without a final response",
            metrics,
        );
    }
    return PiMemorySessionResult(output, metrics);
}

private string[] piMemoryCommand(
    string profileId,
    SessionAutoMemoryTurn turn,
    ProfileRuntimeSettings settings,
)
{
    auto executable = resolvePiExecutable(settings.piCommand);
    if (!executable.path.length) {
        throw new Exception(executable.detail);
    }

    return [
        executable.path,
        "--mode", "json",
        "--print",
        "--provider", settings.piProvider,
        "--model", settings.piModel,
        "--thinking", piThinkingLevel(settings.reasoningMemoryMode),
        "--session-id", memoryPiSessionId(profileId, turn),
        "--session-dir", turn.turnRoot,
        "--name", "wheatley memory " ~ profileId,
        "--no-tools",
        "--no-extensions",
        "--extension", settings.piGenerationExtensionPath,
        "--approve",
    ];
}

private string piMemoryFailureMessage(int exitStatus, string output)
{
    auto message = "Pi memory session exited with status " ~ exitStatus.to!string;
    auto detail = output.strip;
    return detail.length ? message ~ ":\n" ~ limitPiText(detail, 16_384) : message;
}

private string memoryPiSessionId(string profileId, SessionAutoMemoryTurn turn)
{
    return safeId("wheatley-memory-" ~ profileId ~ "-" ~ turn.sessionId ~ "-" ~ baseName(turn.turnRoot));
}

private string memoryRequestMarkdown(
    string templateText,
    string profileId,
    string updatedAt,
    ProfilePromptDocuments documents,
    string batchMarkdown,
)
{
    return templateText
        .replace("<profile_name>", profileId)
        .replace("<updated_at>", updatedAt)
        .replace("<system.md>", contentOrEmpty(documents.systemPrompt))
        .replace("<user.md>", contentOrEmpty(documents.userPrompt))
        .replace("<memory_auto.md>", contentOrEmpty(documents.autoMemory))
        .replace("<completed_user_messages.md>", contentOrEmpty(batchMarkdown))
        .strip ~ "\n";
}

private string memoryMessageDate(string startedAt)
{
    auto clean = startedAt.strip;
    if (
        clean.length >= 10
        && clean[4] == '-'
        && clean[7] == '-'
    ) {
        return clean[0 .. 10];
    }
    return clean;
}

private string contentOrEmpty(string text)
{
    auto clean = text.strip;
    return clean.length ? clean : "(empty)";
}

private struct BatchCounts
{
    long sessions;
    long messages;
}

private BatchCounts batchCounts(string markdown)
{
    bool[string] sessions;
    BatchCounts result;
    foreach (line; markdown.splitLines) {
        auto clean = line.strip;
        if (clean.startsWith("- Session: `") && clean.length > 13 && clean[$ - 1] == '`') {
            sessions[clean[12 .. $ - 1]] = true;
        }
        if (clean.startsWith("- Turn: `")) result.messages++;
    }
    result.sessions = cast(long) sessions.length;
    return result;
}

private void validateAutoMemoryMarkdown(string markdown)
{
    enforce(looksLikeMemoryMarkdown(markdown), "Memory output did not start with #");
}

private bool looksLikeMemoryMarkdown(string markdown)
{
    return markdown.strip.startsWith("#");
}

private string normalizeMarkdown(string text)
{
    auto clean = text.strip;
    return clean.length ? clean ~ "\n" : "";
}

private string sanitizeAutoMemoryMarkdown(string text)
{
    return text.replace("**", "");
}

unittest
{
    assert(memoryMessageDate("2026-07-10T08:13:45.578517Z") == "2026-07-10");
    assert(memoryMessageDate("unknown") == "unknown");
    assert(sanitizeAutoMemoryMarkdown("# **Memory**") == "# Memory");
    assert(looksLikeMemoryMarkdown("# Memory"));
    assert(looksLikeMemoryMarkdown("\n\n## Memory"));
    assert(!looksLikeMemoryMarkdown("Memory updated."));
    assert(!looksLikeMemoryMarkdown(""));
}

private void emitMemoryStart(void delegate(string kind, string message) emitSystem, ProfileRuntimeSettings settings)
{
    if (emitSystem !is null) emitSystem("memory_update_start", settings.memoryUpdateStartMessage);
}

private void emitMemoryDone(void delegate(string kind, string message) emitSystem, ProfileRuntimeSettings settings)
{
    if (emitSystem !is null) emitSystem("memory_update_done", settings.memoryUpdateDoneMessage);
}

private void emitMemoryFailure(void delegate(string kind, string message) emitSystem, ProfileRuntimeSettings settings)
{
    if (emitSystem !is null) emitSystem("memory_update_failed", settings.memoryUpdateFailedMessage);
}
