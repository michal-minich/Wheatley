# Product Behavior

Status: implemented contract, 2026-08-21.

Wheatley is a local-first personal and family assistant. A profile owns its
instructions, configuration, sessions, artifacts, memory, and scheduled tasks.
The browser, Tauri shell, and console clients are views and input/output
devices over the same server-owned conversation behavior.

## Profile instructions

- A chat begins with the active profile's System and User instruction texts.
  Every profile uses the same generic System document. It contains the former
  Agent runtime/tool rules, shared operating rules, and scheduled-task policy,
  while containing no personal or profile-identity content.
- System is also the editable runtime-context template. Wheatley substitutes
  only placeholders that remain in that document: `<profile_name>`,
  `<workspace_folder_path>`, `<workspace_file:WHEATLEY.md>`,
  `<standing_user_profile_instructions>`, and `<memory>`. Removing a placeholder
  removes that block; an empty System document produces no standing or runtime
  system context. At session start Wheatley reads `WHEATLEY.md` from the
  selected workspace and substitutes an empty string when it is absent. The
  resulting authored context is frozen for that session; edits affect new
  sessions. Pi context file discovery is always disabled; Wheatley never loads
  `AGENTS.md`.
- `<working_root>`, `<workspace_instructions>`,
  `<conversation_derived_memory>`, `<recent_wheatley_conversation>`,
  `<profile_system_instructions>`, and `<current_date>` are retired. The former
  cross-profile recent-turn collector and `session.context_turns` setting are
  removed; current-chat continuity remains owned by Pi and cross-chat context by
  Memory.
- User owns the profile identity, audience/person context, response preferences,
  and explicitly remembered durable context. Existing profile-specific System,
  User, and manual Memory content is preserved together in User. System and User
  may use `<default_response_language>` for the resolved conversation language.
  All editable instruction substitutions use the same `<name>` syntax; the
  retired `{{DEFAULT_RESPONSE_LANGUAGE}}` spelling is not supported.
- There is no manual Memory document, Turn wrapper, or separate Agent document.
  The instruction editor exposes System, User, Workspace, Memory, and Memory
  rules, in that order. Workspace directly edits `WHEATLEY.md` in the profile's
  configured workspace; a missing file appears as empty, and saving empty
  Workspace content deletes the file.
- The Workspace tab exposes a **Workspace path** field below its document; the
  field stays hidden on every other instruction tab. Its value is stored as
  `workspace.path` in the selected profile's `config.json`; relative
  paths resolve from that profile's folder. Saving a new path and Workspace
  content writes the content in the new workspace and leaves the old workspace
  untouched. The directory must already exist. New Pi sessions use this profile
  workspace, while an existing Pi session retains its recorded working directory.
  Auto memory remains chat-derived context maintained by its separate
  consolidation process.
- Scheduled occurrences receive only factual scheduler context privately. The
  execution policy remains inspectable in System, and the visible stored task
  text remains literal after creation.

## Conversations

- Each session has one server-owned chronological admission order. User text,
  voice text, images, and scheduled occurrences take their place when Wheatley
  durably admits them; an overdue scheduler poll does not move an occurrence
  ahead of already admitted user messages.
- An untouched chat has no Model context. The first real Pi turn emits it as
  that turn's first presentable activity, before the initiating item in durable
  presentation, live UI, restored history, and the activity side panel. Its
  localized user-facing text is “I'm reading my initializing instructions”.
  Ordinary later turns do not create another Model context item.
- Opening Model context shows the exact rendered System-context snapshot saved
  for the first turn. It does not replace that context with the separate Pi user
  message that initiated the first turn.
- When a scheduled occurrence is admitted into an existing chat, Wheatley adds
  one clickable tool-style item: `Scheduled task <title> will run`. That same
  item becomes running, then completed or failed; it opens the frozen occurrence
  details and is never duplicated by a second trigger after execution starts.
- A scheduled item is a barrier in the admission order. Adjacent user steering
  messages before it may be delivered together at Pi's next boundary, the
  scheduled occurrence runs next, and user messages admitted afterward remain
  after it.
- Live presentation and presentation rebuilt after reload have the same order.
  Opening a chat while a turn is running shows its persisted progress and then
  follows new events from the current point.
- Reasoning and tool activity appear as they occur. Every tool call is persisted
  and shown as a running item before execution; the same item becomes succeeded
  or failed when Pi receives its result. This lifecycle applies to all tools,
  not only long-running or specially rendered tools.
- Starting an empty chat does not display Model context or start a hidden Pi
  turn. The first real turn emits Model context once, ordered immediately before
  that turn's initiating user or scheduled-task record in live and restored
  presentation.
- The transcript groups only contiguous activity into one preview. Model
  context and later reasoning are therefore separate when the initiating item
  lies between them. “Show only recent thinking” keeps only the latest such
  activity run; an earlier model-context preview disappears through that same
  general rule once later reasoning or tool activity exists. Each visible
  preview has its own selection identity even when two runs belong to the same
  turn. Selecting a preview shows exactly that run in the side panel, and only
  selecting that same preview again closes it. The panel preserves activity
  chronology, with model context first when its run is selected or all activity
  is shown.
- A failed accepted turn remains visibly failed after reload. The chat provides
  a concise error and an inspectable technical detail; a transient banner may
  supplement but does not replace that durable state.
- While Pi is working, the web composer remains usable. Sending non-empty text
  creates a normal user bubble and queues the message through the server-owned
  SessionQueue. It does not cancel the current generation or tool execution.
- The dispatcher claims only the earliest ready queue item and runs one item per
  session. A later accepted message keeps its immutable sequence and waits for
  the preceding item, including scheduled barriers, to reach a terminal state.
- Interleaved live events are routed by their canonical turn ID, so a parent
  response and several steering turns cannot append into one another's
  reasoning, tool, artifact, or assistant bubbles.
- A draft or server-accepted message not yet delivered to Pi is a
  semi-transparent user bubble in a shared FIFO tail after all Pi activity.
  Pi's user-message boundary makes that stable bubble opaque and moves its turn
  group into the canonical timeline. Late activity for an older turn inserts
  into that older group rather than appearing after the newer user bubble.
- Repeating a submission while it is pending or running attaches a read-only
  observer to its durable event journal. It never stops, fails, or re-executes
  the server-owned Pi run. Closing every client therefore does not stop
  accepted work; reconnect uses a snapshot and ordered follow.
- When a transcription, spelling, instruction, or required assumption is
  materially unclear, the assistant asks one short clarifying question instead
  of silently guessing.

## Profile generation settings

Every resolved profile has an explicit maximum output-token value. The shipped
default is 8,192 tokens; this is configuration, not a runtime fallback. A
profile may override that value in its own configuration.

A profile may declare optional sampling settings per model and reasoning level:
temperature, `top_p`, `top_k`, `min_p`, presence penalty, and repetition
penalty. An omitted setting is absent from the provider request. Wheatley sends
a configured setting only through an officially supported Pi/provider field;
unsupported configured capability is reported clearly rather than approximated
or translated through an undocumented request shape.

Reasoning controls reflect the selected model's actual capability rather than a
Wheatley-wide four-level abstraction. A binary model uses an on/off control with
no level decoration. A model with multiple supported efforts exposes only those
efforts, using `Min`, `L`, `M`, `H`, `XH`, and `Max` where the corresponding
levels actually exist. Wheatley neither displays nor accepts a level that the
model does not support.

Qwen3.8 27B currently exposes exactly Off, L, M, and XH. Wheatley does not add
an H choice between M and XH.

## Scheduled tasks

- Each occurrence is a real conversation turn owned by one profile and has an
  inspectable scheduled-task trigger.
- On the first successful save of a newly created task, Wheatley stores its
  task text as `This is a scheduled task run:\n\n<LLM-provided task text>`.
  The prefix is ordinary visible task text: the user or agent may edit or remove
  it later. Subsequent edits are literal and never re-add the prefix; editing an
  unrelated field preserves the text exactly. The task-text limit includes the
  prefix. Existing tasks are unchanged.
- A task can be created, inspected, edited, enabled, disabled, rescheduled, run
  immediately, and deleted through both the UI and the agent tools where the
  action applies.
- Editing includes the task title, task text, target, schedule, recurrence, and
  other user-editable details, not only enabled state or next time.
- **Run now** creates one manual occurrence for an enabled, disabled, or
  needs-attention task. Running a disabled task leaves it disabled and leaves
  its future schedule unchanged. A disabled task can therefore serve as a
  reusable manual prompt template.
- A tool validation failure identifies the rejected field and expected shape
  in model-visible text so the assistant can correct the call.
- Every task stores a configured reasoning effort. When an agent omits it during
  creation, Wheatley copies the persistent effort currently selected for the
  creating chat, excluding a one-turn `think` override; the agent may specify a
  different effort explicitly.
- A task targeting a new session pins its creation model and requires that exact
  model/effort pair on create and update. If the pair is unsupported, saving
  fails. If it becomes unavailable later, the occurrence fails and the task is
  marked needs attention; Wheatley does not substitute another model or effort.
- A task targeting its originating user session keeps its configured effort but
  may execute with the nearest effort supported by that session's current
  model. Equal-distance choices prefer the higher effort. The occurrence records
  both configured and effective effort, and adaptation never rewrites the task.
- A scheduled occurrence uses its own effective effort for that turn only. It
  never changes the user's persistent chat setting or the effort used by later
  ordinary turns, and it does not leak reasoning-template markers into answer
  text.
- Once a scheduled occurrence has been admitted and its `will run` item is
  visible, it is claimed. Disabling the task then affects future occurrences,
  not that queued occurrence.
- An active client can yield voice presentation for a scheduled interjection
  without losing its current recording candidate. Music, capture, and speech
  return to a coherent state after the scheduled turn.

## Voice and transcription

- Browser/Tauri and console voice share the server's live-candidate and final
  transcription behavior.
- Browser live listening can retain one physical microphone stream across
  candidate boundaries. **Keep microphone on** is a saved
  per-profile preference shown only while music and automatic response speech
  are both off. In that mode, the next candidate reuses the existing worklet
  graph, keeps the waveform moving, buffers every frame recorded during final
  transcription, and delivers that buffer to the next candidate before its new
  live frames. It does not wait for the assistant. An empty submission returns
  to listening instead of showing a terminal live-recording failure.
  Otherwise Wheatley stops the actual media tracks, waits for assistant output
  to finish, and reacquires the microphone for the next candidate. Hidden output
  settings do not overwrite the saved microphone preference.
- The browser's temporary live-submission identity is replaced by the server's
  canonical turn identity at acceptance. The live response stream owns that
  local turn's presentation; the session-wide stream recognizes and ignores the
  same local submission instead of rendering a second user message, Model
  context item, reasoning run, or assistant response.
- Server thinking-music commands are subject to the current profile's local
  **Play music** preference. An off preference stops or suppresses those
  commands during live voice just as it does during text turns. Continuous
  capture also suppresses thinking music so microphone input remains clean.
- Stable-prefix reuse never retains an annotation-only prefix such as repeated
  bracketed sound descriptions. If normalizing a retained prefix produces no
  spoken text, Wheatley discards both that prefix and its retained audio before
  final transcription.
- A changing partial transcript does not briefly duplicate its last suffix
  when a newer draft replaces it.
- When browser capture is suspended by the browser or operating system,
  Wheatley reports the capture interruption and preserves the last truthful
  candidate state. Background capture is offered only where the browser can
  sustain it reliably.
- The broader hands-free and background-capture acceptance work remains in
  [Continuous Listening](../design/Continuous%20Listening.md).

## Navigation and responsiveness

- Home, New chat, recent-chat entries, and other persistent destinations are
  real links. Normal activation keeps the single-page behavior; browser link
  actions such as right-click and open-in-new-tab work natively.
- Hovering the Home link opens a compact recent-chat menu containing chats
  started in the last three days, with at least three entries when available
  and at most twelve. Its entries are menu-styled links with compact relative
  ages of at most two units. A short close delay lets the pointer cross from
  the Home button into the menu, and entering the menu cancels that close.
- The recent-chat activity filter is a joined 4-by-2 icon grid. Used filters
  occupy the leading cells; unused final cells keep the grid shape and are not
  interactive or hoverable but retain the same background. The hovered filter
  name appears below the grid. An active filter remains visibly active while
  its toolbar toggle is hovered.
- Menus, compact popovers, and dialogs use one profile-tinted drop shadow.
- Scheduled-task list rows have no redundant historical-run bell at the end.
- Home, New chat, opening a scheduled task, and opening an existing chat respond
  from bounded summaries or one direct read rather than repeated whole-history
  scans.
- A chat obtains one history snapshot when opened or reconnected and then
  follows ordered events. Routine five-second full-session polling is absent.
- Open copies of one chat receive the same accepted, delivered, activity, and
  terminal events. The console also follows ordinary turns submitted by web or
  another client and resumes that observation after a transport interruption.
  Home views reconcile the lightweight recent-chat index so chats created or
  changed by other clients appear there as well.
- Going Home ends an unaccepted live microphone candidate and releases its
  capture. Already accepted turns remain server-owned background work, so Home,
  New chat, and recent-chat navigation never wait for their model response.
- New chat is always the first visible toolbar action on Home and chat screens.
  In an open chat, Home is the second action. Both remain visible while Pi is
  working; New chat detaches from accepted background work instead of waiting
  for it.

## Inspectability and presentation

- Assistant bubbles expose local completion time, model, the exact turn-frozen
  reasoning budget, and turn duration in their tooltip as localized
  `key: value` lines. `Reasoning budget: High`, for example, appears immediately
  after `Model`, with both label and value localized. Completed-turn metrics stay
  in that tooltip rather than appearing as visible response text. Input appears
  as exact tokens, compact binary K, and its whole percentage of the context
  window. Context is split into `Used context: <exact> (<K>) <percent>` and
  `Available context: <exact window> (<K>)`; exact counts have no grouping
  separators, and percentages are rounded from exact values. The first-token
  timing label is `Time to first token`.
  Reasoning usage includes the `tokens` unit, and generation speed uses
  `tokens/s`; the rate covers provider generation intervals rather than tool
  execution. Intermediate answer segments do not repeat the whole-turn metrics.
- The activity side panel has no thinking header or collapsed reasoning state.
  Reasoning is always shown in full, including after reopening an in-progress
  chat; historical preview text is loaded automatically when necessary. Thinking
  and tool items expose their own duration as a localized `Duration: value`
  tooltip on the complete item, with millisecond precision.
  The console prints thinking, tool, and final-answer durations in gray after
  the corresponding block, while the full final metrics line is wholly gray.
  These presentation strings are never added to model-visible content, copied
  response text, or speech output. Console profile prefixes have no space after
  `>`.
- Token counts, context use, time to first token, prefill rate, and generation
  rate appear only when Pi or the provider supplies an authoritative value.
  Wheatley does not count stream chunks as tokens and does not use a private
  tokenizer or LM Studio log scraping for display metrics.
- Tool details show the exact arguments Pi sent and the exact content Pi
  returned to model context. Friendly extracted fields and timing are secondary
  views over that observation, never replacements for it.
- The default detail view is readable and pretty-prints structured JSON. A
  **Raw** view preserves the exact call and result. If content is malformed JSON,
  the readable view reports that formatting is unavailable and the Raw view
  remains fully usable; presentation parsing never fails the tool or turn.
- A tool detail title contains the tool name and status icon without a repeated
  `Tool details:` prefix, duplicate name, Pi call identifier, call index, or
  redundant end timestamp. Browser-visible dates use browser-local time.
- JSON, shell/CLI, Python, and other common fenced-code languages receive safe
  syntax highlighting in assistant Markdown and detail dialogs.
- Binary tool content is represented in model-visible text by an explicit
  placeholder and remains available as a named downloadable artifact. Images
  can be previewed and opened at full size.

## Generated images

- A generated image is saved as a session artifact and is available to later
  model turns through Pi's supported image input.
- Generated images have a stable session-local positive ordinal independent of
  uploaded images and screenshots. The model-visible generation result contains
  only `generated_image_id` for this identity and a label such as
  `Generated image 3`; internal artifact locators remain runtime metadata. The
  original generation instruction and surrounding conversation remain the
  semantic description.
- A branch inherits generated-image IDs already present at its branch point and
  allocates the next number after the inherited maximum. Uploads and screenshots
  never consume a generated-image ID.
- Requests such as “compare the first and last generated image” resolve through
  those stable IDs. The model can list session-generated images and load selected
  image content; Wheatley does not attach every historical image to every turn.
