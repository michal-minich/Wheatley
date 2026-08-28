module wheatley.client.console.text.types;

import wheatley.common.api.text_turn : TextTurnMetrics;

struct ConsoleTextTurnResult
{
    string turnId;
    string assistantText;
    string language;
    bool stopped;
    TextTurnMetrics metrics;
}
