module wheatley.server.history.store.profile_documents;

import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.file : exists, readText, remove;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;

import wheatley.common.json.object :
    jsonObject,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.api.profile_replica :
    ProfileReplicaDocument,
    ProfileReplicaSnapshot,
    profileReplicaDocumentSha256,
    profileReplicaSnapshotFromJson,
    profileReplicaSnapshotJson;
import wheatley.common.runtime.now_iso : nowIso;
import wheatley.server.history.profiles.prompt_context_types : ProfilePromptDocuments;
import wheatley.server.history.store.json :
    jsonText,
    objectField,
    readJsonFile,
    readOptionalText,
    writeJsonFileAtomic,
    writeJsonFile,
    writeTextFile;
import wheatley.server.history.store.locations : HistoryStoreLocations;
import wheatley.server.history.store.metrics : ensureObjectField;
import wheatley.server.profiles.config_properties :
    ProfileConfigProperty,
    flattenConfigProperties;

package(wheatley.server.history) final class HistoryProfileDocuments
{
    private HistoryStoreLocations locations;
    private bool replicaDocumentsEnabled;

    this(HistoryStoreLocations locations)
    {
        this.locations = locations;
    }

    ProfileConfigProperty[] configProperties(string profileId)
    {
        auto path = buildPath(locations.profileRoot(profileId), "config.json");
        if (!exists(path)) return [];
        auto config = Json.parse(readText(path)).value;
        return flattenConfigProperties(config);
    }

    void enableReplicaDocuments()
    {
        replicaDocumentsEnabled = true;
    }

    ProfilePromptDocuments promptDocuments(string profileId)
    {
        auto root = locations.profileRoot(profileId);
        auto replica = buildPath(root, "profile_replica_documents.json");
        if (replicaDocumentsEnabled && exists(replica))
            return replicaPromptDocuments(profileId, replica);
        return ProfilePromptDocuments(
            readOptionalText(buildPath(root, "system.md")),
            readOptionalText(buildPath(root, "user.md")),
            readOptionalText(buildPath(root, "memory_auto.md")),
        );
    }

    void applyReplicaDocuments(ProfileReplicaSnapshot snapshot)
    {
        enforce(locations.profileRoot(snapshot.profileId).length, "Profile replica identity is required");
        validateReplicaDocuments(snapshot);
        writeJsonFileAtomic(
            buildPath(locations.profileRoot(snapshot.profileId), "profile_replica_documents.json"),
            profileReplicaSnapshotJson(snapshot),
        );
    }

    string sessionAutoMemoryCursor(string profileId)
    {
        auto path = buildPath(locations.profileRoot(profileId), "config.json");
        if (!exists(path)) return "";
        auto payload = parseJSON(readText(path));
        return jsonText(objectField(payload, "memory"), "last_built_session");
    }

    string sessionAutoMemoryStateJson(string profileId)
    {
        auto cursor = sessionAutoMemoryCursor(profileId);
        if (cursor.length) {
            return jsonObject([jsonStringField("last_built_session", cursor)]);
        }
        return readJsonFile(buildPath(locations.profileRoot(profileId), "memory_auto.json"), "null");
    }

    void saveSessionAutoMemoryCursor(string profileId, string sessionId)
    {
        auto path = buildPath(locations.profileRoot(profileId), "config.json");
        auto payload = exists(path) ? Json.parse(readText(path)).value : parseJSON("{}");
        ensureObjectField(payload, "memory");
        payload.object["memory"].object["last_built_session"] = JSONValue(sessionId);
        writeJsonFile(path, payload.toString());
    }

    void clearSessionAutoMemoryCursor(string profileId)
    {
        auto path = buildPath(locations.profileRoot(profileId), "config.json");
        if (exists(path)) {
            auto payload = Json.parse(readText(path)).value;
            auto memory = "memory" in payload.object;
            if (memory !is null && memory.type == JSONType.object) {
                memory.object.remove("last_built_session");
                if (!memory.object.length) payload.object.remove("memory");
                writeJsonFile(path, payload.toString());
            }
        }
        auto legacyPath = buildPath(locations.profileRoot(profileId), "memory_auto.json");
        if (exists(legacyPath)) remove(legacyPath);
    }

    void appendUserPreference(string profileId, string memory, string timestamp)
    {
        import std.array : appender;
        import std.algorithm : endsWith;

        auto path = buildPath(locations.profileRoot(profileId), "user.md");
        auto current = readOptionalText(path);
        auto output = appender!string;
        if (current.length) {
            output.put(current);
            if (!current.endsWith("\n")) output.put("\n");
        }
        if (!current.canFind("## Remembered preferences and context")) {
            if (current.length) output.put("\n");
            output.put("## Remembered preferences and context\n\n");
        }
        output.put("- ");
        output.put(timestamp);
        output.put(": ");
        output.put(memory);
        output.put("\n");
        writeTextFile(path, output.data);
    }





}

private ProfilePromptDocuments replicaPromptDocuments(string profileId, string path)
{
    auto snapshot = profileReplicaSnapshotFromJson(parseJSON(readText(path)));
    enforce(snapshot.profileId == profileId, "Profile replica document identity changed");
    validateReplicaDocuments(snapshot);
    string[string] content;
    foreach (document; snapshot.documents) content[document.name] = document.content;
    return ProfilePromptDocuments(
        content["system.md"],
        content["user.md"],
        content["memory_auto.md"],
    );
}

private void validateReplicaDocuments(ProfileReplicaSnapshot snapshot)
{
    bool[string] seen;
    foreach (document; snapshot.documents) {
        enforce(
            document.name == "system.md" || document.name == "user.md" ||
                document.name == "memory_auto.md",
            "Profile replica document is unsupported",
        );
        enforce(!(document.name in seen), "Profile replica document is duplicated");
        seen[document.name] = true;
        enforce(document.sha256 == profileReplicaDocumentSha256(document.content),
            "Profile replica document SHA-256 is invalid");
    }
    enforce(seen.length == 3, "Profile replica document snapshot is incomplete");
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    import wheatley.common.api.profile_replica : profileReplicaDocumentSha256;

    auto root = buildPath(tempDir(), "wheatley-profile-replica-documents-" ~ randomUUID().toString());
    scope(exit) rmdirRecurse(root);
    auto profileRoot = buildPath(root, "Profiles", "tester");
    mkdirRecurse(profileRoot);
    writeTextFile(buildPath(profileRoot, "system.md"), "local system");
    auto documents = new HistoryProfileDocuments(new HistoryStoreLocations(
        buildPath(root, "Profiles"),
        root,
    ));
    auto snapshot = ProfileReplicaSnapshot(
        "tester",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        [],
        [
            replicaDocument("system.md", "server system"),
            replicaDocument("user.md", "server user"),
            replicaDocument("memory_auto.md", "server auto"),
        ],
    );
    assert(documents.promptDocuments("tester").systemPrompt == "local system");
    documents.enableReplicaDocuments();
    documents.applyReplicaDocuments(snapshot);
    auto active = documents.promptDocuments("tester");
    assert(active.systemPrompt == "server system");
    assert(active.userPrompt == "server user");
    assert(active.autoMemory == "server auto");
    assert(readText(buildPath(profileRoot, "system.md")) == "local system");

    writeTextFile(buildPath(profileRoot, "user.md"), "# User\n");
    documents.appendUserPreference("tester", "Keep this preference.", "2026-08-20T12:00:00Z");
    auto userInstructions = readText(buildPath(profileRoot, "user.md"));
    assert(userInstructions.canFind("## Remembered preferences and context"));
    assert(userInstructions.canFind("2026-08-20T12:00:00Z: Keep this preference."));
    assert(!exists(buildPath(profileRoot, "memory.md")));
}

private ProfileReplicaDocument replicaDocument(string name, string content)
{
    return ProfileReplicaDocument(name, content, profileReplicaDocumentSha256(content));
}
