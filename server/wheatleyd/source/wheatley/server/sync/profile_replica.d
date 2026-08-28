module wheatley.server.sync.profile_replica;

import std.exception : enforce;
import std.file : exists, mkdirRecurse, readText, tempDir;
import std.json : parseJSON;
import std.path : buildPath;

import wheatley.common.api.profile_replica :
    ProfileReplicaProperty,
    ProfileReplicaDocument,
    ProfileReplicaSnapshot,
    profileReplicaDocumentSha256,
    profileReplicaSnapshotFromJson,
    profileReplicaSnapshotJson;
import wheatley.common.safe_token : enforceSafeToken;
import wheatley.server.history.store.json : writeJsonFileAtomic;

/// Device-local, acknowledged copy of server profile product state for one
/// paired profile. It is a replica artifact, never a second writer.
final class ProfileReplicaStore
{
    private string root;

    this(string root)
    {
        enforce(root.length, "Profile replica root is required");
        this.root = root;
        mkdirRecurse(root);
    }

    void acknowledge(ProfileReplicaSnapshot snapshot)
    {
        validate(snapshot);
        auto path = snapshotPath(snapshot.profileId);
        if (exists(path)) {
            auto current = load(snapshot.profileId);
            if (current.revision == snapshot.revision) return;
        }
        writeJsonFileAtomic(path, profileReplicaSnapshotJson(snapshot));
    }

    bool existsFor(string profileId)
    {
        return exists(snapshotPath(profileId));
    }

    ProfileReplicaSnapshot load(string profileId)
    {
        auto path = snapshotPath(profileId);
        enforce(exists(path), "Acknowledged profile replica is missing");
        auto snapshot = profileReplicaSnapshotFromJson(parseJSON(readText(path)));
        enforce(snapshot.profileId == profileId, "Profile replica identity changed");
        validate(snapshot);
        return snapshot;
    }

    private string snapshotPath(string profileId)
    {
        enforceSafeToken(profileId, "Profile replica profile");
        return buildPath(root, profileId, "snapshot.json");
    }
}

private void validate(ProfileReplicaSnapshot snapshot)
{
    enforceSafeToken(snapshot.profileId, "Profile replica profile");
    enforce(snapshot.revision.length == 64, "Profile replica version is invalid");
    foreach (ch; snapshot.revision) {
        enforce(
            (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'),
            "Profile replica version is invalid",
        );
    }
    foreach (property; snapshot.properties) {
        enforce(property.path.length, "Profile replica property path is empty");
        enforce(property.valueType.length, "Profile replica property type is empty");
    }
    foreach (document; snapshot.documents) {
        enforce(
            document.name == "system.md" || document.name == "user.md" ||
                document.name == "memory_auto.md",
            "Profile replica document is unsupported",
        );
        enforce(document.sha256 == profileReplicaDocumentSha256(document.content),
            "Profile replica document SHA-256 is invalid");
    }
    enforce(snapshot.documents.length == 3, "Profile replica document snapshot is incomplete");
}

unittest
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-profile-replica-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto replicas = new ProfileReplicaStore(root);
    auto first = ProfileReplicaSnapshot(
        "tester",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        [ProfileReplicaProperty("runtime.value", "int", "", 1, 0, false)],
        replicaDocuments(),
    );
    replicas.acknowledge(first);
    assert(replicas.existsFor("tester"));
    assert(replicas.load("tester") == first);

    auto second = first;
    second.revision = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
    second.properties[0].integer = 2;
    replicas.acknowledge(second);
    assert(replicas.load("tester") == second);
}

private ProfileReplicaDocument[] replicaDocuments()
{
    return [
        replicaDocument("system.md", "system"),
        replicaDocument("user.md", "user"),
        replicaDocument("memory_auto.md", "auto"),
    ];
}

private ProfileReplicaDocument replicaDocument(string name, string content)
{
    return ProfileReplicaDocument(name, content, profileReplicaDocumentSha256(content));
}
