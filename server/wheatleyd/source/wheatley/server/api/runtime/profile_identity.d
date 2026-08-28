module wheatley.server.api.runtime.profile_identity;

import std.exception : enforce;

import vibe.http.server : HTTPServerRequest;

import wheatley.server.history.store : HistoryStore;

string requireProfileId(HTTPServerRequest req, HistoryStore store)
{
    auto profileId = req.params["profile_id"];
    enforce(store.profileExists(profileId), "Profile not found");
    return profileId;
}
