module wheatley.server.instructions.documents;

import std.algorithm.searching : canFind;
import std.array : appender, join;
import std.exception : enforce;
import std.file : copy, exists, isDir, isFile, mkdirRecurse, readText, remove, rename, write;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName, isAbsolute;
import std.string : strip;
import std.uuid : randomUUID;

import wheatley.common.json.object : jsonObject, jsonRawField, jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.server.history.store.json : prettyJson, readOptionalText;

enum InstructionDocumentId : string
{
    system = "system",
    user = "user",
    workspace = "workspace",
    autoMemory = "auto_memory",
    memoryRules = "memory_rules",
}

private immutable DocumentDefinition[] definitions = [
    DocumentDefinition(InstructionDocumentId.system, "System", "system.md", false, []),
    DocumentDefinition(InstructionDocumentId.user, "User", "user.md", false, []),
    DocumentDefinition(InstructionDocumentId.workspace, "Workspace", "WHEATLEY.md", false, []),
    DocumentDefinition(InstructionDocumentId.autoMemory, "Memory", "memory_auto.md", false, []),
    DocumentDefinition(InstructionDocumentId.memoryRules, "Memory rules", "session-auto-memory.md", true, [
        "<profile_name>",
        "<updated_at>",
        "<system.md>",
        "<user.md>",
        "<memory_auto.md>",
        "<completed_user_messages.md>",
    ]),
];

private struct DocumentDefinition
{
    string id;
    string label;
    string filename;
    bool appWide;
    string[] requiredPlaceholders;
}

private struct PendingDocument
{
    string path;
    string content;
    string stagedPath;
    string backupPath;
    bool existed;
    bool deleteTarget;
    bool published;
}

final class InstructionDocuments
{
    private string profilesRoot;
    private string promptsRoot;

    this(string profilesRoot, string promptsRoot)
    {
        enforce(profilesRoot.strip.length, "Profiles root is required");
        enforce(promptsRoot.strip.length, "Private prompts root is required");
        this.profilesRoot = profilesRoot;
        this.promptsRoot = promptsRoot;
    }

    string snapshotJson(string profileId)
    {
        auto documents = appender!string;
        documents.put("[");
        foreach (index, definition; definitions) {
            if (index) documents.put(",");
            documents.put(jsonObject([
                jsonStringField("id", definition.id),
                jsonStringField("label", definition.label),
                jsonStringField("scope", definition.appWide ? "app" : "profile"),
                jsonStringField("content", content(profileId, definition)),
            ]));
        }
        documents.put("]");
        return jsonObject([
            jsonStringField("profile_id", profileId),
            jsonStringField("workspace_path", workspacePath(profileId)),
            jsonRawField("documents", documents.data),
        ]);
    }

    string saveJson(string profileId, Json request)
    {
        auto requestedWorkspacePath = request.nonEmpty("workspace_path").strip;
        enforce(requestedWorkspacePath.length, "Workspace path is required");
        auto requestedWorkspaceRoot = resolveWorkspaceRoot(profileId, requestedWorkspacePath);
        enforce(exists(requestedWorkspaceRoot) && isDir(requestedWorkspaceRoot),
            "Workspace path does not exist: " ~ requestedWorkspaceRoot);

        string[string] contentById;
        foreach (document; request.objects("documents")) {
            auto id = document.text("id");
            enforce(!(id in contentById), "Instruction document is duplicated: " ~ id);
            contentById[id] = document.text("content");
        }
        enforce(contentById.length == definitions.length, "Instruction document set is incomplete");

        PendingDocument[] pending;
        auto transactionId = randomUUID().toString();
        foreach (definition; definitions) {
            auto content = idContent(contentById, definition.id);
            validate(definition, content);
            auto target = path(profileId, definition, requestedWorkspaceRoot);
            pending ~= PendingDocument(
                target,
                content,
                target ~ ".pending-" ~ transactionId,
                target ~ ".backup-" ~ transactionId,
                exists(target),
                definition.id == InstructionDocumentId.workspace && !content.strip.length,
                false,
            );
        }
        auto profileConfigPath = buildPath(profileRoot(profileId), "config.json");
        pending ~= PendingDocument(
            profileConfigPath,
            updatedProfileConfig(profileConfigPath, requestedWorkspacePath),
            profileConfigPath ~ ".pending-" ~ transactionId,
            profileConfigPath ~ ".backup-" ~ transactionId,
            exists(profileConfigPath),
            false,
            false,
        );

        scope(failure) rollback(pending);
        foreach (ref document; pending) {
            mkdirRecurse(dirName(document.path));
            if (!document.deleteTarget) write(document.stagedPath, document.content);
            if (document.existed) copy(document.path, document.backupPath);
        }
        foreach (ref document; pending) {
            if (exists(document.path)) remove(document.path);
            if (!document.deleteTarget) rename(document.stagedPath, document.path);
            document.published = true;
        }
        cleanup(pending);
        return snapshotJson(profileId);
    }

    string runtimeTemplate(string id)
    {
        auto definition = requireDefinition(id);
        enforce(definition.appWide, "Instruction document is not an app-wide template: " ~ id);
        auto templatePath = path("", *definition);
        enforce(exists(templatePath), definition.label ~ " prompt template is missing: " ~ templatePath);
        auto content = readText(templatePath);
        validate(*definition, content);
        return content.strip;
    }

    string workspaceRoot(string profileId)
    {
        return resolveWorkspaceRoot(profileId, workspacePath(profileId));
    }

    string workspacePath(string profileId)
    {
        auto configPath = buildPath(profileRoot(profileId), "config.json");
        enforce(exists(configPath) && isFile(configPath),
            "Profile config does not exist: " ~ configPath);
        auto configuredPath = Json.parse(readText(configPath))
            .object("workspace")
            .nonEmpty("path")
            .strip;
        enforce(configuredPath.length, "Profile workspace path is required");
        return configuredPath;
    }

    private string path(
        string profileId,
        scope const ref DocumentDefinition definition,
        string resolvedWorkspaceRoot = "",
    )
    {
        if (definition.id == InstructionDocumentId.workspace) {
            auto root = resolvedWorkspaceRoot.length ? resolvedWorkspaceRoot : workspaceRoot(profileId);
            return buildPath(root, definition.filename);
        }
        return definition.appWide
            ? buildPath(promptsRoot, definition.filename)
            : buildPath(profileRoot(profileId), definition.filename);
    }

    private string content(string profileId, scope const ref DocumentDefinition definition)
    {
        auto target = path(profileId, definition);
        enforce(!exists(target) || isFile(target),
            definition.label ~ " document is not a file: " ~ target);
        return readOptionalText(target);
    }

    private string profileRoot(string profileId)
    {
        return buildPath(profilesRoot, profileId);
    }

    private string resolveWorkspaceRoot(string profileId, string configuredPath)
    {
        auto path = isAbsolute(configuredPath)
            ? configuredPath
            : buildPath(profileRoot(profileId), configuredPath);
        return absolutePath(buildNormalizedPath(path));
    }
}

private string updatedProfileConfig(string path, string workspacePath)
{
    auto config = exists(path) ? Json.parse(readText(path)).value : parseJSON("{}");
    Json.object(config, "profile config");
    auto workspace = "workspace" in config.object;
    if (workspace is null) {
        config.object["workspace"] = parseJSON("{}");
        workspace = "workspace" in config.object;
    }
    Json.object(*workspace, "profile config.workspace");
    workspace.object["path"] = JSONValue(workspacePath);
    return prettyJson(config) ~ "\n";
}

private string idContent(string[string] contentById, string id)
{
    auto value = id in contentById;
    enforce(value !is null, "Instruction document is missing: " ~ id);
    return *value;
}

private const(DocumentDefinition)* requireDefinition(string id)
{
    foreach (ref definition; definitions) {
        if (definition.id == id) return &definition;
    }
    throw new Exception("Unsupported instruction document: " ~ id);
}

private void validate(scope const ref DocumentDefinition definition, string content)
{
    if (!definition.appWide) return;
    enforce(content.strip.length, definition.label ~ " prompt template is empty");
    foreach (placeholder; definition.requiredPlaceholders) {
        enforce(
            content.canFind(placeholder),
            definition.label ~ " prompt template is missing " ~ placeholder,
        );
    }
}

private void rollback(ref PendingDocument[] pending) nothrow
{
    foreach_reverse (ref document; pending) {
        try {
            if (document.published && exists(document.path)) remove(document.path);
            if (exists(document.backupPath)) rename(document.backupPath, document.path);
            if (exists(document.stagedPath)) remove(document.stagedPath);
        } catch (Throwable) {}
    }
}

private void cleanup(ref PendingDocument[] pending) nothrow
{
    foreach (ref document; pending) {
        try if (exists(document.backupPath)) remove(document.backupPath);
        catch (Throwable) {}
        try if (exists(document.stagedPath)) remove(document.stagedPath);
        catch (Throwable) {}
    }
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.json : parseJSON;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-instructions-" ~ randomUUID().toString());
    scope(exit) rmdirRecurse(root);
    auto profiles = buildPath(root, "Profiles");
    auto prompts = buildPath(root, "prompts");
    auto profile = buildPath(profiles, "tester");
    mkdirRecurse(buildPath(profile, "files"));
    mkdirRecurse(prompts);
    write(buildPath(profile, "config.json"), `{"workspace":{"path":"files"}}`);
    auto owner = new InstructionDocuments(profiles, prompts);
    string[] fields;
    foreach (definition; definitions) {
        auto content = definition.appWide
            ? definition.requiredPlaceholders.join("\n") ~ "\n"
            : definition.label ~ " body\n";
        fields ~= jsonObject([
            jsonStringField("id", definition.id),
            jsonStringField("content", content),
        ]);
    }
    auto request = Json.parse(jsonObject([
        jsonStringField("workspace_path", "files"),
        jsonRawField("documents", "[" ~ fields.join(",") ~ "]"),
    ]));
    auto saved = parseJSON(owner.saveJson("tester", request));
    assert(saved.object["documents"].array.length == 5);
    assert(saved.object["workspace_path"].str == "files");
    assert(readText(buildPath(profiles, "tester", "system.md")) == "System body\n");
    assert(readText(buildPath(profile, "files", "WHEATLEY.md")) == "Workspace body\n");
    assert(owner.runtimeTemplate(InstructionDocumentId.memoryRules).canFind("<profile_name>"));

    auto otherWorkspace = buildPath(profile, "other");
    mkdirRecurse(otherWorkspace);
    foreach (ref field; fields) {
        auto document = Json.parse(field);
        if (document.text("id") == InstructionDocumentId.workspace)
            field = jsonObject([
                jsonStringField("id", InstructionDocumentId.workspace),
                jsonStringField("content", "Moved workspace body\n"),
            ]);
    }
    request = Json.parse(jsonObject([
        jsonStringField("workspace_path", "other"),
        jsonRawField("documents", "[" ~ fields.join(",") ~ "]"),
    ]));
    owner.saveJson("tester", request);
    assert(readText(buildPath(profile, "files", "WHEATLEY.md")) == "Workspace body\n");
    assert(readText(buildPath(otherWorkspace, "WHEATLEY.md")) == "Moved workspace body\n");
    assert(owner.workspacePath("tester") == "other");

    foreach (ref field; fields) {
        auto document = Json.parse(field);
        if (document.text("id") == InstructionDocumentId.workspace)
            field = jsonObject([
                jsonStringField("id", InstructionDocumentId.workspace),
                jsonStringField("content", ""),
            ]);
    }
    request = Json.parse(jsonObject([
        jsonStringField("workspace_path", "other"),
        jsonRawField("documents", "[" ~ fields.join(",") ~ "]"),
    ]));
    owner.saveJson("tester", request);
    assert(!exists(buildPath(otherWorkspace, "WHEATLEY.md")));
}
