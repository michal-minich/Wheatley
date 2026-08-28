module wheatley.server.startup.session_resume_answers;

import wheatley.common.api.profile_startup : ProfileSessionResumeAnswers;
import wheatley.server.profiles.config_properties :
    ProfileConfigIndex,
    activeProfileLanguage,
    localizedConfigList;

ProfileSessionResumeAnswers loadSessionResumeAnswers(
    ProfileConfigIndex props,
    string requestedLanguage,
)
{
    auto language = activeProfileLanguage(props, requestedLanguage);
    return ProfileSessionResumeAnswers(
        localizedConfigList(props, language, "session.resume.yes_words"),
        localizedConfigList(props, language, "session.resume.no_words"),
        localizedConfigList(props, language, "session.resume.yes_answers"),
        localizedConfigList(props, language, "session.resume.no_answers"),
    );
}
