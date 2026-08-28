module wheatley.client.console.tools.events;

import std.json : parseJSON;

import wheatley.common.json.read : Json;
import wheatley.client.console.ui.output : color, writeLine, writePrompt, writeToken;
import wheatley.client.console.ui.turn_metrics : compactConsoleDuration;

string handleConsoleToolEvent(
    ref bool assistantPrefixOpen,
    ref bool toolLineOpen,
    string dataJson,
)
{
    auto json = Json.parse(dataJson);
    if (json.text("stage") == "end") {
        if (toolLineOpen) {
            writeToken(" " ~ color(
                compactConsoleDuration(json.nonNegativeInt("duration_ms")),
                "gray",
            ));
            closeConsoleToolLine(toolLineOpen);
        }
        return "";
    }
    json.choice!("start")("stage");
    closeConsoleAssistantLine(assistantPrefixOpen);

    auto message = json.text("message");
    auto displayPrefix = json.text("display_prefix");
    if (json.boolean("prefix_only")) {
        closeConsoleToolLine(toolLineOpen);
        writePrompt(displayPrefix, "orange");
        toolLineOpen = true;
        return "";
    }

    if (toolLineOpen) {
        writeToken(message);
    } else {
        writePrompt(displayPrefix, "cyan");
        writeToken(message);
        toolLineOpen = true;
    }

    auto spokenMessage = json.text("spoken_message");
    return spokenMessage.length ? spokenMessage : message;
}

void closeConsoleToolLine(ref bool toolLineOpen)
{
    if (!toolLineOpen) return;
    writeLine();
    toolLineOpen = false;
}

void closeConsoleAssistantLine(ref bool assistantPrefixOpen)
{
    if (!assistantPrefixOpen) return;
    writeLine();
    assistantPrefixOpen = false;
}
