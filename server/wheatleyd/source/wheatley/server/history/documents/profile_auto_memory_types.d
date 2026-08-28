module wheatley.server.history.documents.profile_auto_memory_types;

struct SessionAutoMemoryMessage
{
    string sessionId;
    string turnId;
    string startedAt;
    string userText;
}

struct SessionAutoMemoryBacklog
{
    string currentSessionId;
    string newestSessionId;
    long sessionCount;
    SessionAutoMemoryMessage[] messages;
}

struct SessionAutoMemoryPlan
{
    bool enabled;
    bool failed;
    string errorMessage;
    long processedSessions;
    long processedMessages;
    string batchMarkdown;
    bool processTodoAfterRecovery;
}

struct SessionAutoMemoryTurn
{
    string turnId;
    string sessionId;
    string sessionRoot;
    string turnRoot;
    string startedAt;
}

struct SessionAutoMemorySave
{
    SessionAutoMemoryTurn turn;
    string requestMarkdown;
    string outputMarkdown;
    string piSessionDir;
    string newestSessionId;
    long sessionCount;
    long messageCount;
    long inputChars;
    long outputChars;
    string llmMetricsJson;
    string completedAt;
}

struct SessionAutoMemoryFailure
{
    SessionAutoMemoryTurn turn;
    string requestMarkdown;
    string piSessionDir;
    string errorMessage;
    long sessionCount;
    long messageCount;
    long inputChars;
    string llmMetricsJson;
    string completedAt;
}
