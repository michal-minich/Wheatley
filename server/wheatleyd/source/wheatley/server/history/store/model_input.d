module wheatley.server.history.store.model_input;

import std.file : exists, readText;
import std.exception : enforce;
import std.json : parseJSON;

import wheatley.common.json.object :
    jsonBoolField,
    jsonObject,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.server.history.store.json : writeJsonFile;
import wheatley.server.history.store.paths : modelInputJsonPath;

private enum modelInputSchema = "wheatley.model_input.v1";

struct ModelInput
{
    string prompt;
    string startedAt;
    string workingDirectory;
    bool startingContext;
    bool privateContext;
}

package(wheatley.server.history) void writeModelInput(
    string turnRoot,
    ModelInput input,
)
{
    writeJsonFile(modelInputJsonPath(turnRoot), jsonObject([
        jsonStringField("schema", modelInputSchema),
        jsonStringField("prompt", input.prompt),
        jsonStringField("started_at", input.startedAt),
        jsonStringField("working_directory", input.workingDirectory),
        jsonBoolField("starting_context", input.startingContext),
        jsonBoolField("private_context", input.privateContext),
    ]));
}

package(wheatley.server.history) ModelInput loadModelInput(string turnRoot)
{
    auto path = modelInputJsonPath(turnRoot);
    if (!exists(path)) return ModelInput.init;
    auto json = Json.object(parseJSON(readText(path)));
    enforce(json.text("schema") == modelInputSchema, "Unsupported model input schema");
    return ModelInput(
        json.text("prompt"),
        json.text("started_at"),
        json.text("working_directory"),
        json.boolean("starting_context"),
        json.boolean("private_context"),
    );
}

unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    auto root = buildPath(tempDir(), "wheatley-model-input-" ~ randomUUID().toString());
    scope (exit) if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    auto expected = ModelInput("Private\n\nContext\n\nRequest\n", "now", "/work", true, true);
    writeModelInput(root, expected);
    assert(loadModelInput(root) == expected);
}
