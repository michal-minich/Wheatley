module wheatley.server.codex.types;

struct CodexSessionRecord
{
    string profileId;
    string sessionId;
    string sessionRoot;
    string threadId;
    string codexSessionId;
    string createdAt;
    string updatedAt;
    string lastTurnId;
    long lastTurnOrdinal;
    string status;
    string latestReasoning;
    string finalText;
    string errorMessage;
    long eventSequence;
}

struct CodexTurnRecord
{
    long ordinal;
    string threadId;
    string turnId;
    string status;
    string startedAt;
    string updatedAt;
    string completedAt;
    string initialMessage;
    string latestReasoning;
    string finalText;
    string errorMessage;
    string turnRoot;
}

struct CodexDispatchRecord
{
    string id;
    string piTurnId;
    string operation;
    string state;
    string errorKind;
    string errorMessage;
    string createdAt;
    string updatedAt;
    string threadId;
    string turnId;
}

struct CodexMessageResult
{
    bool accepted;
    string message;
    string dispatchId;
}

struct CodexStatusResult
{
    string status;
    bool fresh;
    string updatedAt;
    string contentKind;
    string content;
    bool truncated;
}

struct CodexLiveEvent
{
    long sequence;
    string profileId;
    string sessionId;
    string threadId;
    string turnId;
    string itemId;
    long summaryIndex;
    string kind;
    string operation;
    string text;
    string name;
    string status;
    string timestamp;
    bool recovered;
}
