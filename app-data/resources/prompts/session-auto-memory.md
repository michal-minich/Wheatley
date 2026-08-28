# Auto-Memory Consolidation

Maintain compact cumulative chat-derived memory for profile `<profile_name>`. This is maintenance, not conversation.

Consolidation date: <updated_at>

Return only the complete memory document. Do not use tools, write files, explain, or report status. Wheatley saves the response.

## Retention model

- Treat previous auto memory as retained state and the base of the new document. Carry every still-useful entry forward unless a removal rule below clearly applies.
- New accepted user prompts are incremental evidence: add, correct, confirm, or supersede entries. They are not a complete account of what still matters.
- Absence from recent messages is never evidence that an existing entry is false, finished, or unimportant. A sparse batch must not cause a sparse replacement.
- When uncertain whether an entry remains useful, retain it. Move older context to `Older`; do not delete it merely because it aged.

Remove or rewrite an existing entry only when it is:

1. contradicted or superseded by newer accepted user prompts;
2. a duplicate of system or user instructions;
3. an exact duplicate of another auto-memory entry; or
4. clearly erroneous or trivial noise with no plausible future value.

Do not aggressively prune older entries in one pass. If an entry mixes duplicated reference material with unique chat context, keep the unique part.

## Evidence boundaries

- System and user instructions are authoritative reference blocks supplied separately to normal turns. Use them only for deduplication and contradiction checks. Never copy or paraphrase them into auto memory.
- Previous auto memory is valid chat-derived memory, not a reference block to discard.
- Only new accepted user prompts may create or update facts. A prompt remains evidence when its assistant response was stopped or failed.
- Session and turn metadata identify evidence. If the same session and turn appear again after a retry, consolidate them once rather than treating the duplicate as confirmation.
- Assistant replies, tool output, runtime text, draft transcripts, and this request are not evidence.
- Do not invent facts or infer durable traits from one ambiguous request.

## Dates and aging

- Every nonempty entry is one bullet beginning `- YYYY-MM-DD — `. The date is when the fact was last confirmed or changed by an accepted user prompt.
- Preserve an entry's date when carrying it forward unchanged. Do not refresh dates merely because consolidation ran.
- Date new or changed entries from the supporting message heading. When migrating an undated legacy entry and no supporting date is recoverable, use the consolidation date as its first-recorded date, then preserve it.
- `Facts`, `Preferences`, and `Environment` are durable; never expire them solely by age.
- `Active` is unfinished work or a live concern. Keep it active until evidence says it ended, even if not recently mentioned.
- `Recent` is useful short-term context from roughly the last 30 days.
- `Older` is useful past context that is neither durable nor active. Move aging Recent entries here rather than deleting them.
- Dates organize memory; they are not automatic deletion deadlines.

## Selection and compression

- Retain facts, preferences, decisions, constraints, active work, helpful context, and meaningful outcomes that can improve future replies.
- Merge closely related facts into dense, clear bullets without losing important distinctions.
- Prefer current truth over chronology. Preserve meaningful schedules and deadlines.
- Avoid raw transcripts, command logs, and exhaustive prompt histories; keep their reusable outcome or context.
- Target 700 words or fewer and 36 bullets or fewer. These are compression targets, not permission to discard useful memory; preserve first, compress second.

## Output rules

- First line exactly `# Wheatley Auto Memory`.
- Keep all six second-level headings below, in order. Empty sections are allowed.
- The previous document may use legacy headings. Move its useful entries into the six required sections; never reproduce legacy headings or append a copy of the source document. End the response after `Older`.
- Use only headings, simple bullets, dates, and inline code. No prose preamble, bold, italics, tables, block quotes, code fences, or decoration.
- Never output two consecutive asterisks. Strip Markdown bold markers even when present in source text.

## Reference Blocks: deduplicate only, never copy

<profile_system_reference_do_not_copy>

<system.md>

</profile_system_reference_do_not_copy>

<profile_user_reference_do_not_copy>

<user.md>

</profile_user_reference_do_not_copy>

## Retained Auto Memory: preserve by default

<previous_chat_derived_memory>

<memory_auto.md>

</previous_chat_derived_memory>

## New Accepted User Prompts: incremental evidence

<new_completed_user_messages_only_new_evidence>

<completed_user_messages.md>

</new_completed_user_messages_only_new_evidence>

## Required Output

<required_output_schema>

# Wheatley Auto Memory

## Facts

## Preferences

## Environment

## Active

## Recent

## Older

</required_output_schema>
