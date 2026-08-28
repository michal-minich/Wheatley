module wheatley.server.turns.text.pi_prompt;

import std.algorithm.searching : canFind;
import std.string : indexOf, replace, strip;

import wheatley.server.history.store : HistoryStore;
import wheatley.common.api.session : SessionKey;
import wheatley.server.turns.text.profile_runtime_settings : ProfileRuntimeSettings;

string buildPiContext(
    HistoryStore store,
    SessionKey session,
    string workingRoot,
    string workspaceFile,
    ProfileRuntimeSettings settings,
    bool loadMemory,
)
{
    auto documents = store.profilePromptDocumentsForSession(session);
    auto systemPrompt = promptContextText(documents.systemPrompt);

    auto userPrompt = promptContextText(applyPromptConfig(documents.userPrompt, settings)).strip;

    string autoMemorySection;
    if (loadMemory) {
        auto autoMemory = promptContextText(documents.autoMemory).strip;
        if (settings.memoryAutoEnabled && autoMemory.length) {
            autoMemorySection = "# Conversation-Derived Memory\n\n" ~ autoMemory;
        }
    }

    return renderSystemPromptTemplate(
        systemPrompt,
        session.profileId,
        workingRoot,
        workspaceFile.strip,
        standingUserSection(userPrompt),
        autoMemorySection,
        settings,
    );
}

private string promptContextText(string text)
{
    return text.replace("**", "");
}

private string renderSystemPromptTemplate(
    string templateText,
    string profileId,
    string workspaceFolderPath,
    string workspaceFile,
    string standingUserInstructions,
    string memory,
    ProfileRuntimeSettings settings,
)
{
    auto text = applyPromptConfig(templateText, settings)
        .replace("<profile_name>", profileId)
        .replace("<workspace_folder_path>", workspaceFolderPath)
        .replace("<workspace_file:WHEATLEY.md>", workspaceFile)
        .replace("<standing_user_profile_instructions>", standingUserInstructions)
        .replace("<memory>", memory)
        .strip;
    return text.length ? text ~ "\n" : "";
}

private string standingUserSection(string userPrompt)
{
    auto clean = userPrompt.strip;
    if (!clean.length) return "";
    return "# User Instructions\n\n"
        ~ "These are persistent user-authored profile instructions, separate from the current user turn.\n\n"
        ~ clean;
}

unittest
{
    assert(promptContextText("**Heading:** value") == "Heading: value");
    assert(promptContextText("Keep *single* markers") == "Keep *single* markers");
    assert(standingUserSection("Be concise.").canFind("# User Instructions"));

    ProfileRuntimeSettings settings;
    auto rendered = renderSystemPromptTemplate(
        "# System\n\nBe helpful.\n\n<standing_user_profile_instructions>\n\n"
        ~ "# Runtime Context\n\nProfile: <profile_name>\n\n"
        ~ "Workspace: `<workspace_folder_path>`\n\n<workspace_file:WHEATLEY.md>\n\n"
        ~ "<memory>",
        "atom",
        "/workspace",
        "# Wheatley Workspace",
        standingUserSection("Be concise."),
        "# Memory",
        settings,
    );
    assert(rendered.canFind("Profile: atom"));
    assert(rendered.canFind("Workspace: `/workspace`"));
    assert(rendered.canFind("# Wheatley Workspace"));
    assert(rendered.indexOf("# System") < rendered.indexOf("# User Instructions"));
    assert(rendered.indexOf("# User Instructions") < rendered.indexOf("# Runtime Context"));
    assert(rendered.canFind("# Memory"));
    assert(renderSystemPromptTemplate(
        "",
        "atom",
        "/workspace",
        "# Wheatley Workspace",
        standingUserSection("Be concise."),
        "# Memory",
        settings,
    ).length == 0);
}

private string applyPromptConfig(string text, ProfileRuntimeSettings settings)
{
    text = text.replace("<default_response_language>", settings.defaultResponseLanguage);
    return text;
}

unittest
{
    ProfileRuntimeSettings settings;
    settings.defaultResponseLanguage = "Slovak";
    assert(applyPromptConfig(
        "Response language: <default_response_language>.",
        settings,
    ) == "Response language: Slovak.");
}
