module wheatley.client.console.ui.reasoning_output;

import wheatley.common.json.read : Json;
import wheatley.client.console.ui.output :
    color,
    writeAssistantPrefix,
    writeLine,
    writeToken;
import wheatley.client.console.ui.turn_metrics : compactConsoleDuration;

final class ConsoleReasoningOutput
{
    private bool open;
    private bool* toolLineOpen;
    private bool* assistantPrefixOpen;
    private string assistantName;

    this(ref bool toolLineOpen, ref bool assistantPrefixOpen, string assistantName)
    {
        this.toolLineOpen = &toolLineOpen;
        this.assistantPrefixOpen = &assistantPrefixOpen;
        this.assistantName = assistantName;
    }

    void handle(string dataJson)
    {
        auto json = Json.parse(dataJson);
        auto phase = json.text("phase");
        if (phase == "start") return;
        if (phase == "end") {
            close(json.nonNegativeInt("duration_ms"));
            return;
        }
        if (phase != "delta") throw new Exception("Unsupported reasoning phase: " ~ phase);
        auto text = json.text("text");
        if (!text.length) return;
        if (!open) {
            if (*toolLineOpen) {
                writeLine();
                *toolLineOpen = false;
            }
            if (!*assistantPrefixOpen) writeAssistantPrefix(assistantName);
            *assistantPrefixOpen = true;
            open = true;
        }
        writeToken(color(text, "gray"));
    }

    void close(long durationMs = -1)
    {
        if (!open) return;
        if (durationMs >= 0)
            writeToken(" " ~ color(compactConsoleDuration(durationMs), "gray"));
        writeLine();
        open = false;
        *assistantPrefixOpen = false;
    }
}
