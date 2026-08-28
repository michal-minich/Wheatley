module wheatley.server.scheduled_tasks.scheduler;

import vibe.core.core : Task, runTask;
import vibe.core.core : Timer, setTimer;
import vibe.core.log : logWarn;
import core.time : dur;

import wheatley.common.runtime.now_iso : nowIso;
import wheatley.server.conversation.port : ConversationPort;
import wheatley.server.history.store : HistoryStore;
import wheatley.server.pi.models : PiModels;
import wheatley.server.scheduled_tasks.dispatcher : ScheduledTaskDispatcher;
import wheatley.server.scheduled_tasks.store : ScheduledTaskStore;
import wheatley.server.scheduled_tasks.presence : ActiveChatPresenceRegistry;

/** Process-lifetime pull scheduler.  It deliberately derives candidates from
    task files on every scan and only persists an active claim at dispatch. */
final class Scheduler
{
    private ScheduledTaskStore tasks;
    private ScheduledTaskDispatcher dispatcher;
    private Timer timer;
    private bool polling;

    this(
        HistoryStore history,
        ScheduledTaskStore tasks,
        ConversationPort conversations,
        ActiveChatPresenceRegistry presence,
        PiModels models,
    )
    {
        this.tasks = tasks;
        this.dispatcher = new ScheduledTaskDispatcher(
            history,
            tasks,
            conversations,
            presence,
            models,
        );
    }

    void start()
    {
        if (timer) return;
        timer = setTimer(dur!"seconds"(5), () { poll(); }, true);
        poll();
    }

    void recoverAbandonedClaims()
    {
        auto at = nowIso();
        foreach (profileId; tasks.profileIds()) tasks.reconcileAbandonedClaims(profileId, at);
    }

    void stop()
    {
        if (timer) timer.stop();
    }

    private void poll()
    {
        if (polling) return;
        polling = true;
        runTask(() nothrow {
            scope(exit) polling = false;
            try {
                foreach (profileId; tasks.profileIds()) {
                    try {
                        auto now = nowIso();
                        tasks.purgeExpired(profileId, now);
                        foreach (file; tasks.due(profileId, now)) dispatcher.dispatch(file);
                    } catch (Exception error) {
                        logWarn("Scheduled-task scan failed for %s: %s", profileId, error.msg);
                    }
                }
            } catch (Exception error) {
                logWarn("Scheduled-task profile scan failed: %s", error.msg);
            }
        });
    }

}
