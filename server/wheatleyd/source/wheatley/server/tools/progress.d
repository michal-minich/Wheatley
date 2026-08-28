module wheatley.server.tools.progress;

import std.algorithm.searching : canFind, startsWith;
import std.array : join;
import std.json : JSONType, JSONValue;
import std.path : baseName, stripExtension;
import std.string : indexOf, replace, strip, toLower;

import wheatley.common.json.read : Json;
import wheatley.server.i18n.product_translations : productTranslationText;

struct ToolProgress
{
    string displayMessage;
    string spokenMessage;
}

struct ToolProgressMessages
{
    string modelContext;
    string clientPhotoDisplay;
    string clientPhotoSpoken;
    string screenCapture;
    string memoryStart;
    string imageGeneration;
    string imageSearch;
    string imageSearchFor;
    string search;
    string searchFor;
    string readWebPageDisplay;
    string readWebPageSpoken;
    string readFiles;
    string readNamedFile;
    string readPath;
    string updateFiles;
    string updateNamedFile;
    string updatePath;
    string pythonStart;
    string localCommandDisplay;
    string localCommandSpoken;
    string usingTool;
    string usingNamedTool;
}

ToolProgressMessages loadToolProgressMessages(string resourcesRoot, string language)
{
    ToolProgressMessages messages;
    messages.modelContext = toolMessage(resourcesRoot, language, "modelContext");
    messages.clientPhotoDisplay = toolMessage(resourcesRoot, language, "clientPhotoDisplay");
    messages.clientPhotoSpoken = toolMessage(resourcesRoot, language, "clientPhotoSpoken");
    messages.screenCapture = toolMessage(resourcesRoot, language, "screenCapture");
    messages.memoryStart = toolMessage(resourcesRoot, language, "memoryStart");
    messages.imageGeneration = toolMessage(resourcesRoot, language, "imageGeneration");
    messages.imageSearch = toolMessage(resourcesRoot, language, "imageSearch");
    messages.imageSearchFor = toolMessage(resourcesRoot, language, "imageSearchFor");
    messages.search = toolMessage(resourcesRoot, language, "search");
    messages.searchFor = toolMessage(resourcesRoot, language, "searchFor");
    messages.readWebPageDisplay = toolMessage(resourcesRoot, language, "readWebPageDisplay");
    messages.readWebPageSpoken = toolMessage(resourcesRoot, language, "readWebPageSpoken");
    messages.readFiles = toolMessage(resourcesRoot, language, "readFiles");
    messages.readNamedFile = toolMessage(resourcesRoot, language, "readNamedFile");
    messages.readPath = toolMessage(resourcesRoot, language, "readPath");
    messages.updateFiles = toolMessage(resourcesRoot, language, "updateFiles");
    messages.updateNamedFile = toolMessage(resourcesRoot, language, "updateNamedFile");
    messages.updatePath = toolMessage(resourcesRoot, language, "updatePath");
    messages.pythonStart = toolMessage(resourcesRoot, language, "pythonStart");
    messages.localCommandDisplay = toolMessage(resourcesRoot, language, "localCommandDisplay");
    messages.localCommandSpoken = toolMessage(resourcesRoot, language, "localCommandSpoken");
    messages.usingTool = toolMessage(resourcesRoot, language, "usingTool");
    messages.usingNamedTool = toolMessage(resourcesRoot, language, "usingNamedTool");
    return messages;
}

ToolProgress toolProgress(string tool, JSONValue args, ToolProgressMessages messages)
{
    try {
        return specializedToolProgress(tool, args, messages);
    } catch (Exception) {
        return genericToolProgress(tool, messages);
    }
}

private ToolProgress specializedToolProgress(
    string tool,
    JSONValue args,
    ToolProgressMessages messages,
)
{
    if (tool == "model_context") {
        return ToolProgress(messages.modelContext, "");
    }
    if (tool == "capture_photo") {
        return ToolProgress(messages.clientPhotoDisplay, messages.clientPhotoSpoken);
    }
    if (tool == "capture_screen") {
        return ToolProgress(messages.screenCapture, messages.screenCapture);
    }
    if (tool == "remember") {
        return ToolProgress(messages.memoryStart, messages.memoryStart);
    }
    if (tool == "generate_image") {
        return ToolProgress(messages.imageGeneration, messages.imageGeneration);
    }
    if (tool == "image_search") {
        auto query = requiredArgument(args, "query");
        return ToolProgress(
            messages.imageSearchFor.replace("{query}", quoted(query)),
            messages.imageSearch,
        );
    }
    if (tool == "web_search") {
        auto query = searchDescription(args);
        if (!query.length) return genericToolProgress(tool, messages);
        return ToolProgress(
            messages.searchFor.replace("{query}", quoted(query)),
            messages.search,
        );
    }
    if (tool == "fetch_content") {
        auto url = requiredArgument(args, "url");
        return ToolProgress(
            messages.readWebPageDisplay.replace("{url}", url),
            messages.readWebPageSpoken.replace("{domain}", webHost(url)),
        );
    }
    if (tool == "read") {
        auto path = requiredArgument(args, "path");
        return ToolProgress(
            messages.readPath.replace("{path}", quoted(path)),
            messages.readNamedFile.replace("{name}", spokenFilename(path)),
        );
    }
    if (tool == "write" || tool == "edit") {
        auto path = requiredArgument(args, "path");
        return ToolProgress(
            messages.updatePath.replace("{path}", quoted(path)),
            messages.updateNamedFile.replace("{name}", spokenFilename(path)),
        );
    }
    if (tool == "bash") {
        auto command = requiredArgument(args, "command");
        return ToolProgress(
            messages.localCommandDisplay.replace("{command}", quoted(command)),
            command.toLower.canFind("python")
                ? messages.pythonStart
                : messages.localCommandSpoken,
        );
    }
    return genericToolProgress(tool, messages);
}

private ToolProgress genericToolProgress(string tool, ToolProgressMessages messages)
{
    return ToolProgress(
        tool.length ? messages.usingNamedTool.replace("{tool}", tool) : messages.usingTool,
        messages.usingTool,
    );
}

private string searchDescription(JSONValue args)
{
    auto json = Json.object(args);
    auto query = json.opt.text("query");
    if (!query.isNull) return query.get.strip;
    auto field = "queries" in args.objectNoRef;
    if (field is null || field.type != JSONType.array) return "";
    string[] queries;
    foreach (value; field.array) {
        if (value.type != JSONType.string) return "";
        auto clean = value.str.strip;
        if (clean.length) queries ~= clean;
    }
    return queries.join(" · ");
}

private string toolMessage(string resourcesRoot, string language, string key)
{
    return productTranslationText(resourcesRoot, language, "speech.tools." ~ key);
}

private string requiredArgument(JSONValue args, string name)
{
    return Json.object(args).text(name).strip;
}

private string quoted(string text)
{
    return "`" ~ text ~ "`";
}

private string spokenFilename(string path)
{
    auto name = stripExtension(baseName(path.strip));
    name = name.replace("_", " ").replace("-", " ").strip;
    return name.length ? name : "file";
}

private string webHost(string url)
{
    auto host = url.strip;
    auto scheme = host.indexOf("://");
    if (scheme >= 0) host = host[cast(size_t) scheme + 3 .. $];
    foreach (separator; ['/', '?', '#']) {
        auto index = host.indexOf(separator);
        if (index >= 0) host = host[0 .. cast(size_t) index];
    }
    if (host.startsWith("www.")) host = host[4 .. $];
    return host;
}

unittest
{
    import std.json : parseJSON;

    ToolProgressMessages messages;
    messages.search = "Searching.";
    messages.searchFor = "Searching for {query}.";
    messages.usingTool = "Using a tool.";
    messages.usingNamedTool = "Using {tool}.";

    auto multiple = toolProgress(
        "web_search",
        parseJSON(`{"queries":["first topic","second topic"]}`),
        messages,
    );
    assert(multiple.displayMessage == "Searching for `first topic · second topic`.");
    assert(multiple.spokenMessage == "Searching.");

    auto unknownShape = toolProgress(
        "web_search",
        parseJSON(`{"queries":[17]}`),
        messages,
    );
    assert(unknownShape.displayMessage == "Using web_search.");
    assert(unknownShape.spokenMessage == "Using a tool.");

    auto missingPath = toolProgress("read", parseJSON(`{}`), messages);
    assert(missingPath.displayMessage == "Using read.");
}
