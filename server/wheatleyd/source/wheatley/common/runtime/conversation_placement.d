module wheatley.common.runtime.conversation_placement;

import std.exception : enforce;
import std.string : strip;

import wheatley.common.runtime.deployment : DeploymentComposition;

enum ConversationPlacement
{
    local,
    remote,
}

string conversationPlacementText(ConversationPlacement placement)
{
    final switch (placement) {
        case ConversationPlacement.local: return "local";
        case ConversationPlacement.remote: return "remote";
    }
}

ConversationPlacement parseConversationPlacement(string value)
{
    switch (value) {
        case "local": return ConversationPlacement.local;
        case "remote": return ConversationPlacement.remote;
        default: throw new Exception("Unsupported Conversation placement: " ~ value);
    }
}

void validateConversationPlacement(
    ConversationPlacement placement,
    DeploymentComposition composition,
    string remoteApiBase,
    string syncUpstreamApiBase,
)
{
    final switch (placement) {
        case ConversationPlacement.local:
            enforce(
                !remoteApiBase.length,
                "Local Conversation placement cannot configure a remote API",
            );
            break;
        case ConversationPlacement.remote:
            enforce(
                composition == DeploymentComposition.syncedHybrid,
                "Remote Conversation placement requires synced_hybrid composition",
            );
            enforce(remoteApiBase.length, "Remote Conversation placement requires an API base");
            enforce(
                normalizedApiBase(remoteApiBase) == normalizedApiBase(syncUpstreamApiBase),
                "Remote Conversation and profile sync must use the same authority",
            );
            break;
    }
}

private string normalizedApiBase(string value)
{
    auto result = value.strip;
    while (result.length && result[$ - 1] == '/') result = result[0 .. $ - 1];
    return result;
}

unittest
{
    import std.exception : assertThrown;

    validateConversationPlacement(
        ConversationPlacement.local,
        DeploymentComposition.standaloneLocal,
        "",
        "",
    );
    validateConversationPlacement(
        ConversationPlacement.remote,
        DeploymentComposition.syncedHybrid,
        "http://server/api/",
        "http://server/api",
    );
    assertThrown(validateConversationPlacement(
        ConversationPlacement.local,
        DeploymentComposition.standaloneLocal,
        "http://server/api",
        "",
    ));
    assertThrown(validateConversationPlacement(
        ConversationPlacement.remote,
        DeploymentComposition.standaloneLocal,
        "http://server/api",
        "http://server/api",
    ));
    assertThrown(validateConversationPlacement(
        ConversationPlacement.remote,
        DeploymentComposition.syncedHybrid,
        "",
        "http://server/api",
    ));
    assertThrown(validateConversationPlacement(
        ConversationPlacement.remote,
        DeploymentComposition.syncedHybrid,
        "http://conversation/api",
        "http://sync/api",
    ));
}
