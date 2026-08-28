module wheatley.common.runtime.deployment;

import std.exception : enforce;

enum DeploymentComposition
{
    standaloneLocal,
    syncedHybrid,
}

string deploymentCompositionText(DeploymentComposition composition)
{
    final switch (composition) {
        case DeploymentComposition.standaloneLocal: return "standalone_local";
        case DeploymentComposition.syncedHybrid: return "synced_hybrid";
    }
}

DeploymentComposition parseDeploymentComposition(string value)
{
    switch (value) {
        case "standalone_local": return DeploymentComposition.standaloneLocal;
        case "synced_hybrid": return DeploymentComposition.syncedHybrid;
        default: throw new Exception("Unsupported deployment composition: " ~ value);
    }
}

void validateDeploymentComposition(
    DeploymentComposition composition,
    string syncUpstreamApiBase,
)
{
    final switch (composition) {
        case DeploymentComposition.standaloneLocal:
            enforce(
                !syncUpstreamApiBase.length,
                "standalone_local cannot configure a sync upstream",
            );
            break;
        case DeploymentComposition.syncedHybrid:
            enforce(
                syncUpstreamApiBase.length,
                "synced_hybrid requires a sync upstream",
            );
            break;
    }
}

unittest
{
    import std.exception : assertThrown;

    validateDeploymentComposition(DeploymentComposition.standaloneLocal, "");
    validateDeploymentComposition(DeploymentComposition.syncedHybrid, "http://server/api");
    assertThrown(validateDeploymentComposition(
        DeploymentComposition.standaloneLocal,
        "http://server/api",
    ));
    assertThrown(validateDeploymentComposition(DeploymentComposition.syncedHybrid, ""));
}
