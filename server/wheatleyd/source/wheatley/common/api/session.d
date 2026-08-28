module wheatley.common.api.session;

import std.exception : enforce;
import std.string : strip;

struct SessionKey
{
    string profileId;
    string sessionId;

    this(string profileId, string sessionId)
    {
        this.profileId = profileId.strip;
        this.sessionId = sessionId.strip;
        enforce(this.profileId.length, "Session profile_id is required");
        enforce(this.sessionId.length, "Session session_id is required");
    }

    string value() const
    {
        return profileId ~ "\n" ~ sessionId;
    }
}
