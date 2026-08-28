# Continuity and Presence

Status: idea note for product direction, 2026-08-18. This is not yet an
implementation contract.

## Recommendation

The next useful step is not to wake Wheatley every few minutes and ask the
model whether it should say something. It is to give Wheatley one restrained
way to notice meaningful change and speak at a natural re-entry point.

Start with a **return briefing**:

- when a person opens a genuinely new, still-empty chat, Wheatley checks
  existing durable state for something new or unresolved;
- if nothing deserves attention, the chat stays empty and Wheatley says
  nothing;
- if something does, Wheatley starts one real assistant turn with a concise
  update and at most one useful question; and
- the turn has explicit assistant-initiated provenance, not a fake user
  message.

Example:

> The morning space summary is ready in a new chat. The printer-check task also
> failed and needs attention. Do you want the summary first, or should we look
> at the failed task?

This would make Wheatley feel present without turning it into a notification
feed or pretending that it has been consciously waiting between conversations.

The existing scheduled-task system already supplies most of the difficult
runtime foundation: observer-independent turns, new-session creation, durable
provenance, unseen markers, live streaming, automatic speech, and safe Voice
suspend/resume. Presence should be a small product layer over those facts, not
a second scheduler.

## What continuity means

There are several different needs that should remain separate:

| Need | Canonical owner | Current state |
| --- | --- | --- |
| Stable facts, preferences, and personal context | `memory.md` and `memory_auto.md` | Exists |
| The narrative of one conversation | Session history, Pi history, and context compaction | Exists |
| Something that must happen at a future time | Scheduled task | Exists |
| Something new since the person last paid attention | Unseen/attention state | Partly exists |
| An unfinished topic that may continue in another chat | Small cross-session continuity state | Missing |

Long context does not replace these owners. A 256k window can retain much more
of one session, but it does not decide which other session matters, which task
failed, what has already been seen, or which old topic is still alive.

## 1. Return briefing

### Natural trigger

The best initial trigger is the opening of a new blank chat, not merely opening
Home or resuming an old conversation.

On a text client, Wheatley should allow a short arrival grace period. If the
person starts typing or submits a turn, the briefing is suppressed rather than
queued in front of them. On Voice, the briefing should run only before the new
capture becomes active, or through the already safe suspend/speak/resume path.
It should never interrupt speech merely because the app was opened.

Opening an existing session should normally continue that session without an
unrelated profile-wide briefing. Home can continue showing its durable bells,
new-session markers, activity icons, and filters.

### What is worth mentioning

The first version can derive attention from facts Wheatley already owns:

1. a scheduled task currently in `needs_attention`;
2. an unseen automatic session created by a scheduled task;
3. an unseen scheduled turn in an existing session; and
4. possibly a completed scheduled result that explicitly asks for a user
   decision.

The gate should be deterministic. The model writes the human response only
after the server has found eligible facts. Do not spend an LLM invocation to
discover that nothing happened.

Do not mention:

- every successful recurring task;
- a historical failure followed by a successful run;
- ordinary old chats merely because they exist;
- housekeeping such as title generation or automatic-memory consolidation;
- more than a few items at once; or
- generic greetings pretending to be new information.

When several items exist, prefer unresolved failure or requested human choice,
then the newest unseen result. Collapse the rest into a truthful count.

### Delivery and acknowledgement

The briefing itself should be a normal durable Conversation turn with a new
source such as `presence`, plus a small server-authored trigger event that makes
its reason inspectable. It should streamfollw, render, speak, stop, reload, and
resume through the same path as scheduled turns.

The underlying task or automatic chat remains canonical. Presence should store
only enough acknowledgement to avoid repeating the same briefing after a
restart. Mentioning an unseen result must not silently rewrite or delete it;
the original session should retain its bell/new marker until its actual result
is viewed or played under the existing seen rules.

Useful interaction choices are simple:

- open the relevant result;
- inspect or retry a failed task;
- “not now,” which suppresses the briefing without deleting anything; and
- continue with an unrelated question.

### Tone

The response should normally be one or two short sentences and one question.
For any user profile, it should support agency rather than sound like someone
issuing a list of obligations. “The print check failed; want to inspect it?” is
better than “You still need to fix your failed task.”

Wheatley should not say that it missed someone, was lonely, kept thinking while
idle, or has feelings it does not have. Presence should come from accurate
memory, timing, and initiative rather than emotional simulation.

## 2. Cross-session open threads

The return briefing can work without a new memory system. After using it, the
next likely missing capability is continuity for work that is neither a stable
fact nor a scheduled action.

Examples:

- the person was adjusting wall thickness for a Blender model and may want to
  continue after the first print;
- a Trailmakers mechanism had one unresolved sensor problem;
- Wheatley asked a question whose answer never arrived; or
- a real project ended with a clear next experiment but no chosen time.

If ordinary automatic memory does not handle these well enough, add one small,
inspectable profile document, provisionally `continuity.md`. It should contain
only a few live threads, each with:

- a short title;
- current state;
- the source session and turn;
- what or whom it is waiting for;
- one possible next action; and
- last update time.

The assistant should explicitly resolve or archive a thread when it is done.
Anything with a promised time belongs in Scheduled Tasks instead. Durable
personal facts belong in memory. The full story remains in its source session.

This state could first be updated through explicit model tools after meaningful
turns. A later idle-maintenance pass could propose or reconcile threads, but it
should not create a large hidden life model or continuously summarize every
chat.

Once open threads exist, a return briefing may add one relevant continuation:

> Last time the first enclosure print was waiting for a fit check. Did you try
> it, or should we leave that for later?

It should not recite all open threads. Relevance, recency, and a daily mention
budget matter more than completeness.

## 3. Optional companion presence

Some scheduled initiative could be genuinely enjoyable for the person, but it
should remain visible and user-owned rather than becoming a hidden heartbeat.

Good candidates:

- an occasional relevant “Did you know?” curiosity spark while an active chat
  is already open;
- a bounded follow-up after a likely real-world step, such as asking later how
  a 3D print fitted;
- an after-school or evening check-in chosen by the family;
- a playful random joke or science question within defined hours; and
- a periodic review of one ongoing maker project, with a clear stop rule.

These fit the existing scheduled-task forms: calendar, after-completion, or
agent-managed random recurrence. They should have quiet hours, a visible Off
control, a conservative daily frequency, and an easy “not today.” A scheduled
task created for curiosity should be as inspectable and editable as a reminder.

Avoid a generic model pulse such as “every five minutes, inspect everything and
decide whether to talk.” It consumes model capacity, repeats stale thoughts,
creates hard-to-explain behavior, and makes silence depend on prompt quality.
Event changes and explicit schedules are better triggers.

## 4. What a 5090-class model server changes

An RTX 5090 could materially improve the feeling of presence because generation
latency becomes small enough for an initiated turn to feel conversational
rather than like a background job. It also makes it more plausible to keep
Qwen3.8 27B resident, perform fast prefix reuse, and run small maintenance or
briefing prompts without changing models.

The exact target still needs measurement. The current hardware note estimates
roughly 100–120 tok/s for ordinary Q5-class execution and records specialized
200+ tok/s results; approximately 150 tok/s is a plausible benchmark target,
not a guaranteed application rate. Runtime, quantization, reasoning mode,
thermal limits, and speculative/MTP support can all change it.

The 32 GB card also makes 256k possible but tight. Wheatley's current estimate
for Qwen3.8 27B is:

- Q5 model: about 18.47 GiB;
- 256k Q8/FP8 KV cache: about 8 GiB; and
- total before runtime overhead: about 26.5 GiB.

That suggests one Q4/Q5 long-context worker with a quantized KV cache may fit,
but 256k should be a ceiling, not the normal prompt size. A full long-context
slot reduces room for concurrent scheduled, maintenance, and foreground turns.
Cold-prefilling 256k also remains real work even on a fast GPU. Stable sessions,
prefix caching, relevant retrieval, and context compaction will usually feel
better than repeatedly filling the entire window.

The hardware therefore strengthens this design but does not change its basic
architecture:

- use structured durable continuity to choose context;
- keep ordinary active context closer to the useful 20–60k range;
- use 128k/256k as headroom for long conversations and difficult work; and
- benchmark concurrency separately from headline single-stream decode speed.

Before buying specifically for Wheatley, the decisive test is the exact
Qwen3.8 build and runtime at 128k and 256k: time to first token with cold and
warm prefixes, sustained decode, reasoning modes, VRAM peak, and whether one
briefing or scheduled run can overlap foreground Voice without eviction or
OOM. The broader hardware analysis is in
`2026/Ability/LLM Models/Local Coding Hardware.md`. NVIDIA confirms that the
consumer RTX 5090 has [32 GB GDDR7 and a 512-bit memory
interface](https://www.nvidia.com/en-gb/geforce/graphics-cards/50-series/rtx-5090/).

## Suggested sequence

### Slice 1: return briefing from existing facts

- Trigger only on a genuinely new empty chat.
- Derive eligible items from current scheduled-task and unseen-session state.
- Stay silent when the derived set is empty.
- Submit one `presence` Conversation turn with inspectable provenance.
- Reuse current streaming, speech, Stop, persistence, and Voice-yield behavior.
- Remember only announcement acknowledgement; do not duplicate task/session
  truth.

### Slice 2: use it for a week or two

Observe whether it feels useful, surprising, repetitive, parental, or too
quiet. The important evidence is family use, not only passing tests. Adjust
eligibility and tone before adding more sources.

### Slice 3: add open threads only if real conversations need them

Add the small inspectable continuity owner, explicit update/resolve tools, and
one relevant-thread candidate in a return briefing. Do not automatically mine
all history in the first version.

### Slice 4: opt-in companion schedules

Create a few concrete family-selected experiments—perhaps one curiosity spark
and one maker-project follow-up—with conservative frequency and clear Off/stop
behavior. Generalize only from what the person actually enjoys.

## First-slice acceptance scenarios

1. Opening a new chat with no new attention creates no model turn and no
   greeting.
2. One unseen automatic scheduled result produces one short initiated update
   with a direct route to that result.
3. A task in Needs attention is described accurately and offers inspection or
   retry; an old recovered failure is not mentioned.
4. Several items produce at most a few details plus a count, not a spoken
   notification list.
5. Typing or speaking immediately suppresses the pending briefing.
6. Opening an existing session does not inject unrelated profile news.
7. Reload or daemon restart does not repeat an already delivered briefing.
8. “Not now” suppresses the briefing without deleting the task, result, or
   unseen marker.
9. In Voice, the update speaks once without losing a live candidate or starting
   over the person.
10. Tool details show exactly why the assistant initiated the turn and which
    durable facts were supplied to it.

The decisive family check is simple: after several real returns, does
Wheatley feel as if it remembers the household and notices useful change, or
does it feel like another source of alerts? The first version should be easy to
make quieter.
