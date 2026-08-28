module wheatley.server.turns.audio.session_resume_choice;

import std.algorithm.searching : canFind;
import std.string : split;

import wheatley.common.api.profile_startup : ProfileSessionResumeAnswers;
import wheatley.server.turns.audio.live_transcript_text : normalizeLiveTranscript;

string sessionResumeChoice(string transcript, ProfileSessionResumeAnswers answers)
{
    auto answer = normalizeLiveTranscript(transcript);
    bool heardYes;
    bool heardNo;
    foreach (word; answer.split) {
        if (answers.yesWords.canFind(word)) heardYes = true;
        if (answers.noWords.canFind(word)) heardNo = true;
    }
    if (heardYes != heardNo) return heardYes ? "yes" : "no";
    if (heardYes) return "unclear";
    if (answers.yesAnswers.canFind(answer)) return "yes";
    if (answers.noAnswers.canFind(answer)) return "no";
    return "unclear";
}

unittest
{
    auto english = ProfileSessionResumeAnswers(
        ["yes"],
        ["no"],
        ["yeah", "yep", "yup", "sure"],
        ["nope", "nah", "now", "know", "done", "none"],
    );
    auto slovak = ProfileSessionResumeAnswers(
        ["áno", "ano"],
        ["nie"],
        ["hej"],
        ["ne"],
    );
    assert(sessionResumeChoice("Yes.", english) == "yes");
    assert(sessionResumeChoice("NO", english) == "no");
    assert(sessionResumeChoice("yes, please", english) == "yes");
    assert(sessionResumeChoice("No, start a new session.", english) == "no");
    assert(sessionResumeChoice("yes or no", english) == "unclear");
    assert(sessionResumeChoice("Now.", english) == "no");
    assert(sessionResumeChoice("Done.", english) == "no");
    assert(sessionResumeChoice("None.", english) == "no");
    assert(sessionResumeChoice("Thank you.", english) == "unclear");
    assert(sessionResumeChoice("The expected answer is yes or no.", english) == "unclear");
    assert(sessionResumeChoice("What is Kerbal Space Program?", english) == "unclear");
    assert(sessionResumeChoice("Áno.", slovak) == "yes");
    assert(sessionResumeChoice("ano", slovak) == "yes");
    assert(sessionResumeChoice("Nie, novú reláciu.", slovak) == "no");
    assert(sessionResumeChoice("Nie.", slovak) == "no");
    assert(sessionResumeChoice("yes", slovak) == "unclear");
}
