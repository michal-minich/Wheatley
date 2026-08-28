module wheatley.client.console.text.runner;

import std.stdio : stdin, writeln;
import std.string : strip, toLower;

import wheatley.common.api.reasoning : ReasoningMode, turnReasoningMode;
import wheatley.common.api.text_turn : TextTurnMetrics, TextTurnRequest, newSubmissionId;
import wheatley.common.json.read : Json;
import wheatley.client.console.api.client :
    ConsoleApiClient;
import wheatley.client.console.audio.runtime : ConsoleAudioRuntime;
import wheatley.client.console.config : ConsoleConfig;
import wheatley.client.console.codex.observer : startConsoleCodexObserver;
import wheatley.client.console.conversation.observer : startConsoleConversationObserver;
import wheatley.client.console.conversation.local_submissions :
    clearLocalSubmission,
    markLocalSubmission;
import wheatley.client.console.ui.output :
    color,
    writeAssistantPrefix,
    writeError,
    writeLine,
    writeMutedTurn,
    writeNotice,
    writePrompt,
    writeToken,
    writeTurn,
    writeTimedTurn;
import wheatley.client.console.ui.reasoning_output : ConsoleReasoningOutput;
import wheatley.client.console.ui.turn_metrics :
    compactConsoleDuration,
    consoleTurnMetricsText;
import wheatley.client.console.speech.settings : consoleStreamingSpeechSettings;
import wheatley.client.console.ui.startup_status :
    ConsoleStartupOptions,
    announceConsoleStartup;
import wheatley.client.console.ui.session_resume : promptConsoleSessionResume;
import wheatley.client.console.tools.events :
    closeConsoleAssistantLine,
    closeConsoleToolLine,
    handleConsoleToolEvent;

int runConsoleTextChat(
    ConsoleApiClient client,
    ConsoleAudioRuntime audio,
    ConsoleConfig config,
)
{
    auto startup = client.profileStartupState(config.profileId, config.language);
    auto sessionChoice = promptConsoleSessionResume(startup);
    if (!sessionChoice.answered) return 0;
    if (sessionChoice.resumeLastSession) config.language = startup.language;
    writeln("Wheatley text chat. Ctrl-D or empty line exits.");
    auto result = announceConsoleStartup(
        client,
        audio,
        config,
        "chat",
        ConsoleStartupOptions(
            false,
            sessionChoice.resumeLastSession ? startup.lastSessionId : "",
        ),
    );
    config.language = result.language;
    config.sessionId = result.sessionId;
    auto codexObserver = startConsoleCodexObserver(config.apiBase, config.profileId, config.sessionId);
    auto conversationObserver = startConsoleConversationObserver(
        config.apiBase,
        config.profileId,
        config.sessionId,
        config.deviceId,
    );
    scope(exit) {
        codexObserver.requestStop();
        conversationObserver.requestStop();
        codexObserver.join();
        conversationObserver.join();
    }
    while (true) {
        writePrompt("you", "yellow");
        auto line = stdin.readln();
        if (line is null) {
            writeLine();
            return 0;
        }

        auto text = line.strip;
        if (!text.length || isExitCommand(text)) return 0;
        try {
            runConsoleTextTurn(client, audio, config, config.reasoningMode, text);
        } catch (Exception error) {
            writeError(error.msg);
        }
    }
}

void runConsoleTextTurn(
    ConsoleApiClient client,
    ConsoleAudioRuntime audio,
    ConsoleConfig config,
    ReasoningMode preferredReasoningMode,
    string text,
)
{
    auto reasoningMode = turnReasoningMode(preferredReasoningMode, text);

    auto request = TextTurnRequest(
        config.sessionId,
        text,
        newSubmissionId("console-text"),
        config.deviceId,
        config.language,
        "console_text",
        config.loadMemory,
        reasoningMode,
    );
    markLocalSubmission(request.submissionId);
    scope(exit) clearLocalSubmission(request.submissionId);
    runPersistedConsoleTextTurn(client, audio, config, request);
}

private void runPersistedConsoleTextTurn(
    ConsoleApiClient client,
    ConsoleAudioRuntime audio,
    ConsoleConfig config,
    TextTurnRequest request,
)
{
    auto assistantName = config.profileId.length ? config.profileId : "wheatley";

    if (config.stream) {
        bool emittedTokens;
        bool assistantPrefixOpen;
        bool toolLineOpen;
        auto reasoningOutput = new ConsoleReasoningOutput(
            toolLineOpen,
            assistantPrefixOpen,
            assistantName,
        );
        audio.beginTurn(
            consoleStreamingSpeechSettings(config, config.language),
            request.sessionId,
            request.submissionId,
        );
        scope(failure) audio.cancelTurn();
        auto result = client.streamTextTurn(config.profileId, request, (token) {
            reasoningOutput.close();
            if (toolLineOpen) {
                if (!token.strip.length) return;
                toolLineOpen = false;
                assistantPrefixOpen = true;
            } else if (!assistantPrefixOpen) {
                writeAssistantPrefix(assistantName);
                assistantPrefixOpen = true;
            }
            emittedTokens = true;
            writeToken(token);
            audio.feedSpeech(token);
        }, (dataJson) {
            reasoningOutput.close();
            audio.feedSpeechImmediate(handleConsoleToolEvent(
                assistantPrefixOpen,
                toolLineOpen,
                dataJson,
            ));
        }, (dataJson) {
            reasoningOutput.close();
            handleConsoleStatus(assistantPrefixOpen, toolLineOpen, dataJson);
        }, (dataJson) {
            reasoningOutput.handle(dataJson);
        }, null, null);
        reasoningOutput.close();
        if (!emittedTokens && result.assistantText.length) {
            if (toolLineOpen) {
                toolLineOpen = false;
                assistantPrefixOpen = true;
            } else if (!assistantPrefixOpen) {
                writeAssistantPrefix(assistantName);
                assistantPrefixOpen = true;
            }
            writeToken(result.assistantText);
            audio.feedSpeech(result.assistantText);
        }
        closeConsoleToolLine(toolLineOpen);
        if (assistantPrefixOpen) {
            if (result.metrics.durationMs >= 0)
                writeToken(" " ~ color(
                    compactConsoleDuration(result.metrics.durationMs),
                    "gray",
                ));
            writeLine();
        }
        writeConsoleTurnMetrics(assistantName, result.metrics, result.language);
        audio.setSpeechLanguage(result.language);
        if (result.stopped) {
            audio.stopSpeech();
        } else {
            audio.finishSpeech();
        }
        return;
    }

    auto result = client.streamTextTurn(
        config.profileId,
        request,
        null,
        null,
        (dataJson) {
            bool assistantPrefixOpen;
            bool toolLineOpen;
            handleConsoleStatus(assistantPrefixOpen, toolLineOpen, dataJson);
        },
        null,
        null,
        null,
    );
    writeTimedTurn(
        assistantName,
        result.assistantText,
        result.metrics.durationMs < 0
            ? "" : compactConsoleDuration(result.metrics.durationMs),
    );
    writeConsoleTurnMetrics(assistantName, result.metrics, result.language);
    if (config.speak && !result.stopped && result.assistantText.strip.length) {
        audio.beginTurn(
            consoleStreamingSpeechSettings(config, result.language),
            request.sessionId,
            request.submissionId,
        );
        audio.feedSpeech(result.assistantText);
        audio.finishSpeech();
    }
}

private void writeConsoleTurnMetrics(
    string assistantName,
    TextTurnMetrics metrics,
    string language,
)
{
    auto summary = consoleTurnMetricsText(metrics, language);
    if (summary.length) writeMutedTurn(assistantName, summary);
}

private void handleConsoleStatus(
    ref bool assistantPrefixOpen,
    ref bool toolLineOpen,
    string dataJson,
)
{
    auto status = Json.parse(dataJson);
    auto code = status.text("code");
    if (code != "generated_image" && code != "pi_compaction_started"
        && code != "pi_compaction_completed" && code != "pi_compaction_failed") return;
    closeConsoleAssistantLine(assistantPrefixOpen);
    closeConsoleToolLine(toolLineOpen);
    writeNotice(status.text("message"), code == "pi_compaction_failed" ? "red" : "cyan");
}

private bool isExitCommand(string text)
{
    auto command = text.strip.toLower;
    return command == "quit" || command == "exit";
}
