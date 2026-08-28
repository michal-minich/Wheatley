module wheatley.server.tools.types;

struct ToolCall
{
    string name;
    string argumentsJson;
}

struct ToolResult
{
    string name;
    bool ok;
    string contentJson;
}

struct ExecutedTool
{
    string eventId;
    string timestamp;
    ToolCall call;
    ToolResult result;
    double durationSeconds;
    int callIndex;
    string source;
    string status;
}
