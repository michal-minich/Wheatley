module wheatley.server.scheduled_tasks.repository;

import std.exception : enforce;
import std.file :
    DirEntry,
    SpanMode,
    dirEntries,
    exists,
    isDir,
    readText,
    remove,
    rmdir;
import std.json : JSONValue, parseJSON;
import std.path : baseName, buildPath;

import wheatley.server.history.store.json : writeJsonFileAtomic;

/** Atomic profile-local persistence for task definitions and active claims.
    It deliberately knows no recurrence or lifecycle policy. */
final class ScheduledTaskRepository
{
    private string profilesRoot;

    this(string profilesRoot)
    {
        enforce(profilesRoot.length, "Profiles root is required");
        this.profilesRoot = profilesRoot;
    }

    DirEntry[] entries(string profileId)
    {
        auto root = tasksRoot(profileId);
        if (!exists(root) || !isDir(root)) return [];
        DirEntry[] result;
        foreach (entry; dirEntries(root, SpanMode.shallow))
            if (entry.isDir && exists(buildPath(entry.name, "task.json"))) result ~= entry;
        return result;
    }

    string[] profileIds()
    {
        if (!exists(profilesRoot)) return [];
        string[] result;
        foreach (entry; dirEntries(profilesRoot, SpanMode.shallow))
            if (entry.isDir) result ~= baseName(entry.name);
        return result;
    }

    JSONValue read(string profileId, string id)
    {
        auto path = taskPath(profileId, id);
        enforce(exists(path), "Task not found");
        return parseJSON(readText(path));
    }

    void save(string profileId, string id, JSONValue task)
    {
        writeJsonFileAtomic(taskPath(profileId, id), task.toString());
    }

    void deleteTask(string profileId, string id)
    {
        auto root = taskRoot(profileId, id);
        enforce(exists(root), "Task not found");
        enforce(!claimExists(profileId, id), "Task has an active run");
        remove(taskPath(profileId, id));
        rmdir(root);
    }

    bool claimExists(string profileId, string id)
    {
        return exists(claimPath(profileId, id));
    }

    JSONValue readClaim(string profileId, string id)
    {
        auto path = claimPath(profileId, id);
        enforce(exists(path), "No active scheduled task run");
        return parseJSON(readText(path));
    }

    bool createClaim(string profileId, string id, JSONValue claim)
    {
        auto path = claimPath(profileId, id);
        if (exists(path)) return false;
        writeJsonFileAtomic(path, claim.toString());
        return true;
    }

    void deleteClaim(string profileId, string id)
    {
        auto path = claimPath(profileId, id);
        if (exists(path)) remove(path);
    }

    string taskRoot(string profileId, string id)
    {
        return buildPath(tasksRoot(profileId), id);
    }

private:
    string tasksRoot(string profileId)
    {
        return buildPath(profilesRoot, profileId, "scheduled-tasks");
    }

    string taskPath(string profileId, string id)
    {
        return buildPath(taskRoot(profileId, id), "task.json");
    }

    string claimPath(string profileId, string id)
    {
        return buildPath(taskRoot(profileId, id), "active-run.json");
    }
}
