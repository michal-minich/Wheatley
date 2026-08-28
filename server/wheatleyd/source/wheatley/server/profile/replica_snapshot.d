module wheatley.server.profile.replica_snapshot;

import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;

import wheatley.common.api.profile_replica :
    ProfileReplicaDocument,
    ProfileReplicaProperty,
    ProfileReplicaSnapshot,
    profileReplicaDocumentSha256,
    profileReplicaSnapshotJson;
import wheatley.server.history.profiles.prompt_context_types : ProfilePromptDocuments;
import wheatley.server.profiles.config_properties : ProfileConfigProperty;

ProfileReplicaSnapshot profileReplicaSnapshot(
    string profileId,
    ProfileConfigProperty[] properties,
    ProfilePromptDocuments documents,
)
{
    ProfileReplicaProperty[] entries;
    foreach (property; properties) {
        entries ~= ProfileReplicaProperty(
            property.fieldPath,
            property.valueType,
            property.textValue,
            property.integerValue,
            property.realValue,
            property.boolValue,
        );
    }
    auto documentEntries = [
        ProfileReplicaDocument("system.md", documents.systemPrompt, profileReplicaDocumentSha256(documents.systemPrompt)),
        ProfileReplicaDocument("user.md", documents.userPrompt, profileReplicaDocumentSha256(documents.userPrompt)),
        ProfileReplicaDocument("memory_auto.md", documents.autoMemory, profileReplicaDocumentSha256(documents.autoMemory)),
    ];
    auto unsigned = ProfileReplicaSnapshot(profileId, "pending", entries, documentEntries);
    auto revision = toHexString!(LetterCase.lower)(sha256Of(profileReplicaSnapshotJson(unsigned))).idup;
    return ProfileReplicaSnapshot(profileId, revision, entries, documentEntries);
}

unittest
{
    auto first = profileReplicaSnapshot(
        "tester",
        [ProfileConfigProperty("runtime.value", "int", "", 3)],
        ProfilePromptDocuments("system", "user", "auto"),
    );
    auto second = profileReplicaSnapshot(
        "tester",
        [ProfileConfigProperty("runtime.value", "int", "", 4)],
        ProfilePromptDocuments("system", "user", "auto"),
    );
    assert(first.revision.length == 64);
    assert(first.revision != second.revision);
    assert(first.documents.length == 3);
}
