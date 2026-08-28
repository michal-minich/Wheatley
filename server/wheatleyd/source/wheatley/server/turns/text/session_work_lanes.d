module wheatley.server.turns.text.session_work_lanes;

import vibe.core.sync : TaskMutex, scopedMutexLock;

import wheatley.common.api.session : SessionKey;

final class SessionWorkLanes
{
    private TaskMutex registryMutex;
    private TaskMutex[string] lanes;

    this()
    {
        registryMutex = new TaskMutex;
    }

    TaskMutex get(SessionKey session)
    {
        auto guard = scopedMutexLock(registryMutex);
        auto key = session.value;
        if (auto lane = key in lanes) return *lane;
        auto lane = new TaskMutex;
        lanes[key] = lane;
        return lane;
    }
}

unittest
{
    auto lanes = new SessionWorkLanes;
    auto first = SessionKey("tester", "2026/07/14/10_00_00");
    auto second = SessionKey("tester", "2026/07/14/10_01_00");
    assert(lanes.get(first) is lanes.get(first));
    assert(lanes.get(first) !is lanes.get(second));
}
