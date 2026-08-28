module wheatley.server.history.store.types;

import wheatley.common.api.reasoning : ReasoningMode;

struct PiSessionMetadata
{
    string model;
    string modelName;
    string sessionId;
    string sessionDir;
    string workingRoot;
    string workFolder;
    string extensionPath;
    string updatedAt;
}

struct SessionMetadata
{
    string clientMode;
    string language;
    string model;
    ReasoningMode reasoningMode;
}

struct StoredTurn
{
    string id;
    string profileId;
    string deviceId;
    string source;
    string status;
    string startedAt;
    string completedAt;
    string modelName;
    string language;
    ReasoningMode reasoningMode;
    string userText;
    string assistantText;
    string turnRoot;
    bool hasUserAudio;
    bool hasTools;
    long activityDurationMs = -1;
    long[string] reasoningDurationsMs;
    string submissionId;
    string executionId;
    string submissionJson;
    bool hasUserImage;
    string userImageFilename;
    string userImageMediaType;
    ulong userImageBytes;
    string userImagePath;
    bool branchInherited;
    string metricsJson;
}

struct TurnText
{
    string prompt;
    string response;
}
