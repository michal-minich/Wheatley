module wheatley.server.turns.text.generation_settings;

import std.algorithm.searching : canFind;
import std.exception : enforce;
import std.json : JSONType, JSONValue;

import wheatley.common.api.reasoning : ReasoningMode, reasoningModeText;
import wheatley.common.json.object : jsonBoolField, jsonLongField, jsonObject, jsonRawField;
import wheatley.server.pi.models : PiModelInfo;
import wheatley.server.profiles.config_properties :
    ProfileConfigIndex,
    requiredConfigInt;

struct ResolvedGenerationSettings
{
    long maxOutputTokens;
    string providerRequestJson;
}

private struct OptionalNumber
{
    bool present;
    double value;
}

ResolvedGenerationSettings resolveGenerationSettings(
    ProfileConfigIndex props,
    PiModelInfo model,
    ReasoningMode reasoningMode,
)
{
    auto modelRoot = "generation.models." ~ model.key;
    auto maxOutputTokens = props.hasNonNullValue(modelRoot ~ ".max_output_tokens")
        ? requiredConfigInt(props, modelRoot ~ ".max_output_tokens")
        : requiredConfigInt(props, "generation.max_output_tokens");
    enforce(maxOutputTokens > 0 && maxOutputTokens <= 1_000_000,
        "generation.max_output_tokens must be between 1 and 1000000");

    OptionalNumber[string] values;
    foreach (field; samplingFields) {
        applySamplingLayer(values, props, "generation.sampling", field);
        applySamplingLayer(values, props, modelRoot ~ ".sampling", field);
    }

    auto broadMode = reasoningMode == ReasoningMode.off ? "non_thinking" : "thinking";
    foreach (field; samplingFields) {
        applySamplingLayer(values, props, "generation.sampling." ~ broadMode, field);
        applySamplingLayer(values, props, modelRoot ~ ".sampling." ~ broadMode, field);
    }

    auto exactMode = reasoningModeText(reasoningMode);
    foreach (field; samplingFields) {
        applySamplingLayer(values, props, "generation.sampling.levels." ~ exactMode, field);
        applySamplingLayer(values, props, modelRoot ~ ".sampling.levels." ~ exactMode, field);
    }

    if (auto minP = "min_p" in values) throw new Exception(
        "generation sampling min_p is unsupported by Wheatley's current provider adapters",
    );

    bool hasSampling;
    foreach (field; samplingFields) {
        if (field != "min_p" && (field in values) !is null) hasSampling = true;
    }
    if (hasSampling) enforce(
        model.provider == "lmstudio" && model.api == "openai-completions",
        "Configured generation sampling is unsupported for " ~ model.key
            ~ " (provider " ~ model.provider ~ ", API " ~ model.api ~ ")",
    );
    enforce(
        model.maxTokensField == "max_tokens" || model.maxTokensField == "max_completion_tokens",
        "Unsupported Pi maximum-token request field for " ~ model.key ~ ": "
            ~ model.maxTokensField,
    );

    string[] fields = [jsonLongField(model.maxTokensField, maxOutputTokens)];
    if (model.provider == "lmstudio" && model.api == "openai-completions")
        fields ~= jsonRawField("stream_options", jsonObject([
            jsonBoolField("include_usage", true),
        ]));
    foreach (field; samplingFields) {
        auto configured = field in values;
        if (field == "min_p" || configured is null) continue;
        auto providerField = field == "repetition_penalty" ? "repeat_penalty" : field;
        fields ~= jsonRawField(providerField, JSONValue(configured.value).toString());
    }
    return ResolvedGenerationSettings(maxOutputTokens, jsonObject(fields));
}

private immutable string[] samplingFields = [
    "temperature",
    "top_p",
    "top_k",
    "min_p",
    "presence_penalty",
    "repetition_penalty",
];

private void applySamplingLayer(
    ref OptionalNumber[string] values,
    ProfileConfigIndex props,
    string root,
    string field,
)
{
    auto path = root ~ "." ~ field;
    if (!props.hasNonNullValue(path)) return;
    auto property = path in props.byPath;
    enforce(property !is null, "Missing generation sampling property: " ~ path);
    enforce(property.valueType == "real" || property.valueType == "int",
        "Generation sampling value must be numeric: " ~ path);
    auto value = property.valueType == "real"
        ? property.realValue
        : cast(double) property.integerValue;
    validateSamplingValue(field, value, path);
    values[field] = OptionalNumber(true, value);
}

private void validateSamplingValue(string field, double value, string path)
{
    if (field == "temperature")
        enforce(value >= 0 && value <= 2, path ~ " must be between 0 and 2");
    else if (field == "top_p" || field == "min_p")
        enforce(value >= 0 && value <= 1, path ~ " must be between 0 and 1");
    else if (field == "top_k")
        enforce(value >= 0 && value == cast(long) value, path ~ " must be a nonnegative integer");
    else if (field == "presence_penalty")
        enforce(value >= -2 && value <= 2, path ~ " must be between -2 and 2");
    else if (field == "repetition_penalty")
        enforce(value > 0, path ~ " must be positive");
}

unittest
{
    import std.exception : assertThrown;
    import std.json : parseJSON;
    import std.math : isClose;
    import wheatley.server.profiles.config_properties :
        ProfileConfigProperty,
        indexProfileConfigProperties;

    auto props = indexProfileConfigProperties([
        ProfileConfigProperty("generation.max_output_tokens", "int", "", 8192),
        ProfileConfigProperty(
            "generation.models.lmstudio/qwen.sampling.non_thinking.temperature",
            "real", "", 0, 0.7,
        ),
        ProfileConfigProperty(
            "generation.models.lmstudio/qwen.sampling.thinking.temperature",
            "real", "", 0, 0.6,
        ),
        ProfileConfigProperty(
            "generation.models.lmstudio/qwen.sampling.thinking.repetition_penalty",
            "int", "", 1,
        ),
    ]);
    auto model = PiModelInfo(
        "lmstudio/qwen", "lmstudio", "qwen", "Qwen", true,
        [ReasoningMode.off, ReasoningMode.xhigh], true, 131072,
        "openai-completions", "max_tokens",
    );
    auto off = resolveGenerationSettings(props, model, ReasoningMode.off);
    assert(off.maxOutputTokens == 8192);
    assert(isClose(parseJSON(off.providerRequestJson).object["temperature"].floating, 0.7));
    assert(parseJSON(off.providerRequestJson).object["stream_options"]
        .object["include_usage"].type == JSONType.true_);
    auto thinking = resolveGenerationSettings(props, model, ReasoningMode.xhigh);
    auto thinkingRequest = parseJSON(thinking.providerRequestJson).object;
    assert(isClose(thinkingRequest["temperature"].floating, 0.6));
    assert(isClose(thinkingRequest["repeat_penalty"].floating, 1.0));

    props.byPath["generation.sampling.min_p"] = ProfileConfigProperty(
        "generation.sampling.min_p", "real", "", 0, 0.1,
    );
    assertThrown!Exception(resolveGenerationSettings(props, model, ReasoningMode.off));
}
