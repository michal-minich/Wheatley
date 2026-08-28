module wheatley.client.console.ui.session_resume;

import std.algorithm.searching : canFind;
import std.stdio : stdin, stdout, writeln;
import std.string : strip, toLower;

import wheatley.common.api.profile_startup : ProfileSessionResumeAnswers, ProfileStartupState;

struct ConsoleSessionResumeChoice
{
    bool answered;
    bool resumeLastSession;
}

ConsoleSessionResumeChoice promptConsoleSessionResume(ProfileStartupState startup)
{
    if (!startup.canResumeLastSession) return ConsoleSessionResumeChoice(true, false);
    while (true) {
        stdout.write(startup.messages.textResumePrompt ~ " ");
        stdout.flush();

        auto line = stdin.readln();
        if (line is null) {
            writeln();
            return ConsoleSessionResumeChoice();
        }

        auto answer = parseConsoleSessionResumeAnswer(line, startup.resumeAnswers);
        if (answer == ConsoleSessionResumeAnswer.resume) {
            return ConsoleSessionResumeChoice(true, true);
        }
        if (answer == ConsoleSessionResumeAnswer.newSession) {
            return ConsoleSessionResumeChoice(true, false);
        }
        writeln(startup.messages.textResumeUnclear);
    }
}

private enum ConsoleSessionResumeAnswer
{
    invalid,
    newSession,
    resume,
}

private ConsoleSessionResumeAnswer parseConsoleSessionResumeAnswer(
    string value,
    ProfileSessionResumeAnswers answers,
)
{
    auto answer = value.strip.toLower;
    if (answers.yesWords.canFind(answer) || answers.yesAnswers.canFind(answer))
        return ConsoleSessionResumeAnswer.resume;
    if (answers.noWords.canFind(answer) || answers.noAnswers.canFind(answer))
        return ConsoleSessionResumeAnswer.newSession;
    return ConsoleSessionResumeAnswer.invalid;
}

unittest
{
    auto unavailable = promptConsoleSessionResume(ProfileStartupState());
    assert(unavailable.answered && !unavailable.resumeLastSession);
    auto english = ProfileSessionResumeAnswers(["yes"], ["no"], ["sure"], ["nope"]);
    auto slovak = ProfileSessionResumeAnswers(["áno", "ano"], ["nie"], ["hej"], ["ne"]);
    assert(parseConsoleSessionResumeAnswer(" YES\n", english) == ConsoleSessionResumeAnswer.resume);
    assert(parseConsoleSessionResumeAnswer("no", english) == ConsoleSessionResumeAnswer.newSession);
    assert(parseConsoleSessionResumeAnswer("áno", slovak) == ConsoleSessionResumeAnswer.resume);
    assert(parseConsoleSessionResumeAnswer("ano", slovak) == ConsoleSessionResumeAnswer.resume);
    assert(parseConsoleSessionResumeAnswer("NIE\n", slovak) == ConsoleSessionResumeAnswer.newSession);
    assert(parseConsoleSessionResumeAnswer("yes", slovak) == ConsoleSessionResumeAnswer.invalid);
}
