module wheatley.server.pi.models;

import core.time : dur;

import std.algorithm.searching : canFind;
import std.array : appender, join;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

import vibe.core.core : runTask;
import vibe.core.path : NativePath;
import vibe.core.process : Config, Redirect;
import vibe.stream.operations : readLine;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.api.reasoning : ReasoningMode, reasoningModeText;
import wheatley.common.runtime.process_runner : pipeLocalProcess;
import wheatley.server.turns.text.pi_runtime : resolvePiExecutable;

struct PiModelInfo
{
    string key;
    string provider;
    string model;
    string name;
    bool reasoning;
    ReasoningMode[] reasoningModes;
    bool vision;
    long contextWindow;
    string api;
    string maxTokensField;
}

final class PiModels
{
    private PiModelInfo[] availableModels;
    private PiModelInfo[string] modelsByKey;
    private string[] memoryModelKeys;

    this(string command, string workDir, string[] memoryModelKeys)
    {
        this.availableModels = loadAvailablePiModels(command, workDir);
        enforce(availableModels.length, "Pi has no available models");
        foreach (model; availableModels) {
            enforce((model.key in modelsByKey) is null, "Duplicate Pi model: " ~ model.key);
            modelsByKey[model.key] = model;
        }

        enforce(memoryModelKeys.length, "memory.models must not be empty");
        foreach (key; memoryModelKeys) {
            enforce((key in modelsByKey) !is null, "Memory model is not available in Pi: " ~ key);
            enforce(!this.memoryModelKeys.canFind(key), "Duplicate memory model: " ~ key);
            this.memoryModelKeys ~= key;
        }
    }

    PiModelInfo chatModel(string key)
    {
        return key.length ? get(key) : defaultModel;
    }

    PiModelInfo memoryModel(PiModelInfo chatModel)
    {
        return memoryModelKeys.canFind(chatModel.key) ? chatModel : defaultModel;
    }

    PiModelInfo requireExactReasoning(string key, ReasoningMode mode)
    {
        auto model = chatModel(key);
        enforce(
            model.reasoningModes.canFind(mode),
            "Scheduled task model " ~ model.key ~ " does not support reasoning effort "
                ~ reasoningModeText(mode) ~ "; supported efforts: "
                ~ reasoningModeTexts(model.reasoningModes).join(", "),
        );
        return model;
    }

    PiModelInfo defaultModel()
    {
        return get(memoryModelKeys[0]);
    }

    string json()
    {
        auto rows = appender!string;
        rows.put("[");
        foreach (index, model; availableModels) {
            if (index) rows.put(",");
            rows.put(modelJson(model));
        }
        rows.put("]");
        return jsonObject([
            jsonStringField("default_model", defaultModel.key),
            jsonRawField("models", rows.data),
        ]);
    }

    private PiModelInfo get(string key)
    {
        auto model = key in modelsByKey;
        enforce(model !is null, "Model is not available in Pi: " ~ key);
        return *model;
    }
}

private string[] reasoningModeTexts(ReasoningMode[] modes)
{
    string[] result;
    foreach (mode; modes) result ~= reasoningModeText(mode);
    return result;
}

private PiModelInfo[] loadAvailablePiModels(string command, string workDir)
{
    auto executable = resolvePiExecutable(command);
    enforce(executable.path.length, executable.detail);
    auto pipes = pipeLocalProcess(
        [executable.path, "--mode", "rpc", "--no-session", "--no-tools"],
        Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout,
        null,
        Config.none,
        NativePath(workDir),
    );

    PiModelInfo[] models;
    Exception readError;
    auto outputTask = runTask({
        try {
            while (!pipes.stdout.empty) {
                auto line = (cast(string) pipes.stdout.readLine(4 * 1024 * 1024, "\n")).strip;
                if (!line.length) continue;
                JSONValue payload;
                try {
                    payload = parseJSON(line);
                } catch (Exception) {
                    continue;
                }
                auto id = Json.object(payload).opt.text("id");
                if (id.isNull || id.get != "wheatley-models") continue;
                enforce(Json.object(payload).boolean("success"), "Pi model discovery failed");
                auto data = Json.object(payload).object("data").value;
                models = parsePiModels(requiredArray(data, "models"));
                pipes.stdin.close();
                return;
            }
        } catch (Exception error) {
            readError = error;
        }
    });

    pipes.stdin.write(`{"id":"wheatley-models","type":"get_available_models"}` ~ "\n");
    auto maybeStatus = pipes.process.wait(dur!"seconds"(15));
    if (maybeStatus.isNull) {
        pipes.process.forceKill();
        pipes.process.wait();
    }
    outputTask.join();
    if (readError !is null) throw readError;
    enforce(!maybeStatus.isNull, "Pi model discovery timed out");
    enforce(maybeStatus.get == 0, "Pi model discovery failed");
    enforce(models.length, "Pi model discovery returned no response");
    return models;
}

private PiModelInfo[] parsePiModels(JSONValue[] values)
{
    PiModelInfo[] models;
    foreach (value; values) {
        auto valueJson = Json.object(value);
        auto provider = valueJson.text("provider");
        auto model = valueJson.text("id");
        auto reasoning = valueJson.boolean("reasoning");
        auto compat = valueJson.object("compat");
        models ~= PiModelInfo(
            provider ~ "/" ~ model,
            provider,
            model,
            valueJson.text("name"),
            reasoning,
            reasoning ? parseReasoningModes(value) : [ReasoningMode.off],
            stringArray(value, "input").canFind("image"),
            valueJson.integer("contextWindow", 1),
            valueJson.text("api"),
            compat.text("maxTokensField"),
        );
    }
    return models;
}

private ReasoningMode[] parseReasoningModes(JSONValue model)
{
    ReasoningMode[] result;
    foreach (mode; [
        ReasoningMode.off,
        ReasoningMode.minimal,
        ReasoningMode.low,
        ReasoningMode.medium,
        ReasoningMode.high,
        ReasoningMode.xhigh,
        ReasoningMode.max,
    ]) {
        if (supportsThinkingLevel(model, reasoningModeText(mode))) result ~= mode;
    }
    enforce(result.length, "Reasoning model has no supported Wheatley reasoning modes");
    return result;
}

private bool supportsThinkingLevel(JSONValue model, string level)
{
    auto map = "thinkingLevelMap" in model.objectNoRef;
    if (map is null) return true;
    enforce(map.type == JSONType.object, "thinkingLevelMap must be an object");
    auto value = level in map.objectNoRef;
    return value is null || value.type != JSONType.null_;
}

private JSONValue[] requiredArray(JSONValue payload, string name)
{
    enforce(payload.type == JSONType.object, "Pi RPC data must be an object");
    auto value = name in payload.objectNoRef;
    enforce(value !is null && value.type == JSONType.array, name ~ " must be an array");
    return value.array;
}

private string[] stringArray(JSONValue payload, string name)
{
    string[] result;
    foreach (value; requiredArray(payload, name)) {
        enforce(value.type == JSONType.string, name ~ " values must be strings");
        result ~= value.str;
    }
    return result;
}

private string modelJson(PiModelInfo model)
{
    return jsonObject([
        jsonStringField("id", model.key),
        jsonStringField("provider", model.provider),
        jsonStringField("model", model.model),
        jsonStringField("name", model.name),
        jsonBoolField("reasoning", model.reasoning),
        jsonRawField("reasoning_modes", reasoningModesJson(model.reasoningModes)),
        jsonBoolField("vision", model.vision),
        jsonLongField("context_window", model.contextWindow),
    ]);
}

private string reasoningModesJson(ReasoningMode[] modes)
{
    auto result = appender!string;
    result.put("[");
    foreach (index, mode; modes) {
        if (index) result.put(",");
        result.put(JSONValue(reasoningModeText(mode)).toString());
    }
    result.put("]");
    return result.data;
}

unittest
{
    auto binary = parseJSON(`{
        "provider":"lmstudio",
        "id":"binary",
        "name":"Binary",
        "api":"openai-completions",
        "reasoning":true,
        "thinkingLevelMap":{"off":"none","minimal":null,"low":null,"medium":null,"high":"high","xhigh":null,"max":null},
        "input":["text"]
        ,"contextWindow":32768
        ,"compat":{"maxTokensField":"max_tokens"}
    }`);
    auto graduated = parseJSON(`{
        "provider":"lmstudio",
        "id":"graduated",
        "name":"Graduated",
        "api":"openai-completions",
        "reasoning":true,
        "thinkingLevelMap":{"off":"none","minimal":"minimal","low":"low","medium":"medium","high":null,"xhigh":"xhigh","max":"max"},
        "input":["text","image"]
        ,"contextWindow":131072
        ,"compat":{"maxTokensField":"max_tokens"}
    }`);
    auto plain = parseJSON(`{
        "provider":"lmstudio",
        "id":"plain",
        "name":"Plain",
        "api":"openai-completions",
        "reasoning":false,
        "input":["text"]
        ,"contextWindow":65536
        ,"compat":{"maxTokensField":"max_tokens"}
    }`);

    auto models = parsePiModels([binary, graduated, plain]);
    assert(models[0].reasoningModes == [ReasoningMode.off, ReasoningMode.high]);
    assert(models[1].reasoningModes == [
        ReasoningMode.off,
        ReasoningMode.minimal,
        ReasoningMode.low,
        ReasoningMode.medium,
        ReasoningMode.xhigh,
        ReasoningMode.max,
    ]);
    assert(models[1].vision);
    assert(models[2].reasoningModes == [ReasoningMode.off]);
}
