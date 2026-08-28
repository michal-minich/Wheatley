module wheatley.server.scheduled_tasks.presence;

import std.datetime.systime : SysTime;
import std.exception : enforce;
import std.json : JSONValue;

import wheatley.common.json.read : Json;
import wheatley.common.runtime.now_iso : nowIso;

/** In-memory open-chat leases.  Clients refresh a lease; scheduled-task
    storage never treats presence as durable state. */
final class ActiveChatPresenceRegistry
{
    private ActiveChatPresence[string] entries;

    /** Returns whether a Voice client should yield its microphone turn.  The
        request is intentionally process-local: a browser reconnect never
        replays a stale interruption. */
    bool report(string profileId, JSONValue payload)
    {
        auto json = Json.object(payload, "body");
        auto clientId = json.nonEmpty("client_id");
        auto sessionId = json.nonEmpty("session_id");
        auto phase = json.choice!(
            "idle", "typing", "listening", "transcribing", "model_turn", "speaking", "stopping", "suspended",
        )("phase");
        auto expiresAt = json.nonEmpty("expires_at");
        enforce(SysTime.fromISOExtString(expiresAt) > SysTime.fromISOExtString(nowIso()),
            "Presence lease is already expired");
        auto key = profileId ~ "\0" ~ clientId;
        auto yieldRequested = false;
        if (auto existing = key in entries)
            yieldRequested = existing.yieldRequested
                && phase == "listening";
        entries[key] = ActiveChatPresence(
            profileId,
            clientId,
            json.nonEmpty("device_id"),
            sessionId,
            phase,
            json.boolean("visible"),
            json.nonEmpty("last_interaction_at"),
            expiresAt,
            yieldRequested,
        );
        return yieldRequested;
    }

    string activeSessionId(string profileId, string at)
    {
        ActiveChatPresence best;
        foreach (entry; entries.byValue) {
            if (entry.profileId != profileId) continue;
            if (SysTime.fromISOExtString(entry.expiresAt) <= SysTime.fromISOExtString(at)) continue;
            if (!best.clientId.length || entry.lastInteractionAt > best.lastInteractionAt) best = entry;
        }
        return best.sessionId;
    }

    /** Ask the most recently-interacting live Voice client to release capture
        before an active-session scheduled task is claimed. */
    bool requestVoiceYield(string profileId, string at)
    {
        string bestKey;
        ActiveChatPresence best;
        foreach (key, entry; entries) {
            if (entry.profileId != profileId) continue;
            if (SysTime.fromISOExtString(entry.expiresAt) <= SysTime.fromISOExtString(at)) continue;
            if (entry.phase != "listening") continue;
            if (!best.clientId.length || entry.lastInteractionAt > best.lastInteractionAt) {
                bestKey = key;
                best = entry;
            }
        }
        if (!bestKey.length) return false;
        best.yieldRequested = true;
        entries[bestKey] = best;
        return true;
    }

    /** An active Voice candidate or its response cannot safely compete with a
        scheduler turn.  A listening candidate receives a yield request; later
        phases simply defer admission until the client becomes idle/suspended. */
    bool hasBlockingVoice(string profileId, string at)
    {
        foreach (entry; entries.byValue) {
            if (entry.profileId != profileId) continue;
            if (SysTime.fromISOExtString(entry.expiresAt) <= SysTime.fromISOExtString(at)) continue;
            if (entry.phase == "listening" || entry.phase == "transcribing"
                || entry.phase == "model_turn" || entry.phase == "speaking"
                || entry.phase == "stopping") return true;
        }
        return false;
    }
}

struct ActiveChatPresence
{
    string profileId;
    string clientId;
    string deviceId;
    string sessionId;
    string phase;
    bool visible;
    string lastInteractionAt;
    string expiresAt;
    bool yieldRequested;
}

unittest
{
    import std.datetime : seconds;
    import wheatley.common.runtime.now_iso : nowIso;

    auto registry = new ActiveChatPresenceRegistry;
    auto now = SysTime.fromISOExtString(nowIso());
    assert(!registry.report("tester", JSONValue([
        "client_id": JSONValue("web"),
        "device_id": JSONValue("browser"),
        "session_id": JSONValue("2026/08/17/12_00_00"),
        "phase": JSONValue("typing"),
        "visible": JSONValue(true),
        "last_interaction_at": JSONValue(now.toISOExtString()),
        "expires_at": JSONValue((now + seconds(30)).toISOExtString()),
    ])));
    assert(registry.activeSessionId("tester", now.toISOExtString())
        == "2026/08/17/12_00_00");
    assert(!registry.requestVoiceYield("tester", now.toISOExtString()));
}
