module wheatley.server.api.core.config;

import wheatley.common.runtime.deployment : DeploymentComposition;
import wheatley.common.runtime.conversation_placement : ConversationPlacement;

struct ServerConfig
{
    string appDataRoot;
    string resourcesRoot;
    string configPath;
    string profilesRoot;
    string codexWorkspaceRoot;
    string codexSocket;
    string host;
    ushort port;
    string corsOrigin;
    DeploymentComposition deploymentComposition;
    ConversationPlacement conversationPlacement;
    string conversationRemoteApiBase;
    string syncUpstreamApiBase;
    int syncIntervalSeconds;
}
