# Coding Guide

This cross-project coding guide. It is to be followed by coding agents for coding and coding discussion.

It encodes specific engineering taste for well-designed software across
projects and languages.

The goal is not consensus style, framework fashion, or generic enterprise patterns.

The goal is calm, explicit, durable code: obvious ownership, direct flow, small sharp abstractions, and refactors that make the system easier to reason about.

---

## Readability and flow

- Optimize for local clarity
- Keep code calm, inspectable, and easy to trace
- Let each unit read at one level of intent, with named calls revealing the next level down
- Keep input-to-effect reasoning direct across the resulting call hierarchy
- Prefer directness over cleverness
- If the flow is hard to follow, the code is too noisy

## Ownership and mutation

- Give each mutable fact one owner
- Keep mutation explicit, visible, and repairable
- Prefer clear ownership over shared mutable convenience
- Favor single-writer ownership for mutable state
- Use DDD-lite aggregate ownership where it helps, without heavy ceremony

## Boundaries and policy

- Validate at IO boundaries
- Trust validated data further on
- Keep UI, transport, storage, and domain boundaries explicit
- Use ports and adapters at IO, storage, transport, and UI edges
- Keep reusable mechanism separate from feature policy
- Keep policy in the level that owns the outcome
- Let boundary adapters translate technical operations without choosing product workflow
- Do not let product policy leak into shared mechanisms or technical adapters

## Composition and structure

- Build from small, reusable, orthogonal building blocks
- Compose features from small focused units
- Units like classes and functions should be small and have little code
- Keep each function, class, interface, module, and file at one coherent abstraction level, pragmatically
- Let higher-level code state intent, order, policy, and delegation while lower-level collaborators own detailed mechanics
- Require each extracted level to add a real decision, transformation, invariant, or boundary
- Use capability-oriented design with tiny focused interfaces
- Prefer composition, parameterization, adapters, and small capability interfaces over inheritance
- Keep public surfaces small and literal
- Prefer narrower abstractions over wider ones

## Reuse and refactoring

- Extract shared mechanism from duplication
- Actively look for opportunities to refactor specific code into general, reusable and smaller units, then compose them
- Strongly prefer present needs over hypothetical flexibility
- Let code become simpler under refactoring, not more ornate
- Reuse through composition and parameterization

## Names and contracts

- Use names that state behavior and guarantees
- Make failure behavior predictable from names
- Use strict verbs for strict contracts

## Reader test

- A reader should be able to clearly see data flow, validation, mutation, failure shape, and where shared mechanism ends and feature policy begins
- At each point in the call path, a reader should know the current abstraction level and see deeper details behind named lower-level operations

---

## Recognizable Lineage

These are the closest recognizable influences in the reference material. This section is descriptive, not a claim about direct historical origin.

Closest influences:

- Unix tradition, especially Doug McIlroy, Ken Thompson, Rob Pike, and Brian Kernighan:
  Borrow small blunt tools, narrow responsibilities, and composition of orthogonal parts.
  Do not borrow shell-pipeline mentality applied blindly to in-process code or clever terseness for its own sake.
- David Parnas and information hiding:
  Borrow one clear owner, hidden repair logic behind a small surface, and modules organized by responsibility rather than syntax.
  Do not borrow over-fragmentation when smaller files do not improve ownership.
- Rich Hickey and the "simple vs easy" / mechanism-vs-policy tradition:
  Borrow separation of invariant mechanism from varying policy, resistance to complecting, and direct readable flow.
  Do not borrow forced purity or abstraction vocabularies larger than the problem.
- Martin Fowler, Kent Beck, and refactoring literature:
  Borrow refactoring toward abstractions only after concrete duplication appears, blunt storage and mapping seams, and scenario-focused tests.
  Do not borrow speculative enterprise layering or ceremony-heavy pattern worship.
- Fowler's PoEAA pattern vocabulary:
  Borrow names like `Table`, `Repository`, `Mapper`, `Gateway`, and `Facade`.
  Do not borrow giant service layers, ORM-heavy indirection, or patterns that hide the data flow.
- Alistair Cockburn and ports-and-adapters thinking:
  Borrow explicit IO boundaries, thin directional adapters, and transport or storage kept at the edge.
  Do not borrow use-case or interactor explosions for a small codebase.
- Eric Evans and DDD-lite aggregate ownership:
  Borrow one owner repairing dependent state and protecting invariants, with literal domain language.
  Do not borrow full DDD ceremony, strategic-design taxonomy, or factories and repositories by ritual.
- Go and Rust ecosystem taste:
  Borrow composition over inheritance, small interfaces around actual needs, and explicit ownership and error handling.
  Do not borrow low-levelness for its own sake or trait-like abstraction everywhere.
- GoF patterns used selectively:
  Borrow names like `Facade`, `Adapter`, `Observer`, and `Builder`.
  Do not borrow pattern-driven class hierarchies or abstract factories for simple wiring.
- Niklaus Wirth and recursive-descent compiler style:
  Borrow hand-written tokenizer/parser/AST splits, explicit precedence, and direct control flow for small languages.
  Do not borrow parser-generator ceremony for compact grammars.
- Gary Bernhardt's functional-core / imperative-shell framing:
  Borrow validation and parsing at the edge and trusted inner logic where it helps.
  Do not borrow the idea that every subsystem should become pure or immutable.

---

## Architecture and dependency direction

Organize code in clear layers with obvious dependency direction. The roles below
are illustrative, not mandatory folder names or a prescribed layer count. Each
role may decompose through as many meaningful abstraction levels as the problem
needs.

*Foundation / Core*

- Owns: low-level primitives, helper types, validation, tiny capability interfaces, generic storage or event helpers
- Must not own: product policy, app workflows, feature naming

*Shared domain / Common*

- Owns: reusable domain logic, builders, repositories, facades, persistence mapping, shared transport mechanisms, presentation adapters, local interaction state, reusable UI or platform helpers
- Must not own: concrete persistence or transport orchestration, application policy, app composition

*Application / Feature / Tool*

- Owns: concrete workflows, product-specific commands and views, composition of lower-level parts
- Must not own: hidden cross-feature globals, a second shared-domain layer

*Experiments*

- Owns: spikes, prototypes, not-yet-hardened patterns
- Must not own: architectural defaults

### Direction rules

- Call flow descends from intent and policy toward mechanism and technical APIs
- Lower-level implementations do not reach upward for app-specific decisions
- Higher-level policy depends on small capabilities rather than concrete technical adapters
- Composition roots may know the concrete graph; ordinary feature and mechanism code should not
- UI consumes domain state; it does not own persistence or backend orchestration
- Durable runtime behavior belongs in domain or app owners, not UI

### App and feature layer

The app layer should be composition and feature packaging.

- Assemble concrete services and adapters
- Define product-specific entities, commands, or views that are not reusable enough for lower layers
- Express workflows in feature vocabulary and delegate their subproblems
- Connect generic primitives into a product-specific workflow

If app-specific code becomes reusable, stable, or shared by multiple features, move it down.

### Composition roots

Keep composition explicit:

- Wire concrete collaborators near the application edge
- Choose environment-specific adapters in one readable place
- Let composition code know about lower layers, not the reverse
- Prefer direct construction over containers or registries
- Use small bridge helpers such as `configureXToY(...)` only when they reduce edge noise without hiding ownership

A reader should be able to open the entrypoint and understand the main object graph without solving a framework puzzle.

### Entrypoints and startup

- Move substantial setup into named helpers or app/server owners
- Prefer explicit lifecycle methods like `start`, `stop`, or `run` for work that opens resources or schedules tasks

Prefer a small state-owner class or one clear startup owner over namespace-style module singletons with hidden process lifetime.

### Module ownership

One file should usually have one clear owner at one abstraction level.

Good owners:

- One class with a narrow purpose
- One runtime contract family
- One focused helper namespace or module
- One table, store, adapter, builder, finder, repository, mapper, or facade

Keep the main exports and public names in one vocabulary. Short private helpers
may keep local detail nearby; move a distinct lower-level concern to a focused
collaborator or module.

Preferred shape inside a file:

1. public contracts and types
2. main owner or operations
3. private helpers below

The first screen of a file should explain what it owns.

Split a file when:

- One half is workflow and the other half is plumbing
- Two groups of functions change for different reasons
- A helper starts attracting imports from multiple unrelated callers
- A boundary file starts owning parsing, mapping, validation, and persistence all at once
- Method names cannot be simple verbs

### Abstraction step-down

Keep each function, method, class, interface, module, and file at one coherent
conceptual altitude. Higher levels coordinate, order, choose policy, and
delegate. The next level decomposes its subproblem and makes decisions within
it. Lower levels eventually translate trusted intent into library, protocol,
platform, or hardware operations. Apply this recursively; it is not a fixed
three-layer architecture.

Do not interleave workflow steps with the raw mechanics of one step. Push a
detail down when it introduces a different vocabulary, dependency set,
lifecycle, error model, or invariant. Pull decisions upward when a technical
adapter starts choosing workflow or product policy. Keep short same-vocabulary
detail local, and skip intermediate wrappers that add no meaning.

---

## Ownership and state

This is one of the most important parts of the style.

### Definitions

Owner = the one class or module allowed to mutate a fact and repair all dependent state for that fact.

Dependent state includes things like:

- Reverse links
- Indexes
- Cached values
- Selection state
- Derived collections
- Event ordering

Boundary = anywhere data enters from outside the trusted core, basically IO such as:

- Network
- Storage
- Filesystem
- Process environment
- Parsing text
- Transport payloads
- Browser input
- Public API surfaces

### Rules

- One owner per mutable structure
- Mutation must be explicit and named
- Let the owner express mutation in domain terms and delegate lower-level repair mechanics when they become a separate concern
- Repair dependent state in the same operation
- Emit events only after state is coherent
- Keep related mutation steps physically close
- Expose readonly views when callers should observe but not mutate
- If state has reverse links, indexes, caches, selection state, or derived mirrors, the owner repairs them in the same flow
- If the owner emits events, emit only after the state is coherent
- Sequence counters, queues, validity windows, and watermark state should have one owner that enforces order directly
- Plain data objects are fine
- Related state may stay coupled inside a small owner when all mutation paths are local, explicit, and easy to audit. Extract a helper owner only when the coupling stops being obvious.

---

## Contracts, naming, classes, interfaces, and functions

Names must tell the caller what guarantee they are getting. Use capability-based naming.

### API shape

- Prefer explicit named public declarations
- Prefer file names that match the main exported owner
- Prefer nouns for stateful owners and verbs for actions
- Let the owner carry the noun and the method carry the verb
- Keep the public surface in one vocabulary and abstraction level
- Expose the smallest useful surface behavior unless a facade is intentionally the public
- Do not duplicate owner functionality. Extension-like helpers may provide convenience by composing the owner's public surface
- Events and failures are part of the contract
- When an internal boundary needs only a small capability or plain data shape, pass that narrow view instead of mapping it into another duplicate type

### Capability interfaces

Treat interface broadly: a language interface, protocol, trait, function table,
callback shape, or another explicit capability contract. Keep these contracts
very small. Smaller is better.

- Keep each interface centered on one concern, one abstraction level, and one reason to change
- Compose larger shapes from small focused parts
- Use interface or trait inheritance only for very small, semantically real fragments
- Prefer explicit composition over inheritance
- Do not force unrelated contracts to share a base type just because they both have common fields like `id` or `name`
- Do not mix domain operations and raw transport, storage, OS, or hardware operations in one interface

Names by example:

Clock, Writer, Log, Sender, DbConnection, Storage, Builder, Finder, Store, Codec, Repository, Workspace, Table, Receiver, Sender, Rpc, Facade, Bridge, Adapter, Connection, Server, Translator, Mapper, Aspect, Parser, Printer, View

### Verb guarantees

Name methods by simple verbs when possible.
If simple naming is not possible, the owner may span several concerns or abstraction levels.

- `get` - value must exist
- `tryGet` / `find` - absence is normal
- `create` - create new owned state
- `set` - replace direct owned state
- `add` - attach or append
- `remove` - detach from an owned collection; strict unless prefixed
- `delete` - remove an owned entity entirely
- `mark` - advance state with a specific invariant
- `load` - hydrate or read persisted data
- `save` - write persisted data
- `parse` - interpret external syntax into trusted shape
- `map` / `convert` - transform representation
- `configure` - wire subsystems together

Rules:

- If absence is expected, encode it in the name
- If a method is strict, fail fast on broken preconditions
- Prefer literal domain words over metaphor
- Methods inside a clear owner can be shorter because the owner already provides context
- Standalone functions need more domain words because they lack owner context
- Calls inside a function should read as a short outline in one vocabulary, with their names revealing the next level down
- Reintroduce the noun inside the method name only when one owner spans several domains and the shorter verb becomes unclear
- Very short local names are preferred inside small functions where the role is obvious. Examples: `l`, `u`, `id`, `ix`, `pk`, `ev`, `msg`, `cb`, `e`, `ex`, `err`

### Runtime contracts

Pair static types with runtime contracts at risky boundaries such as IO,
storage, REST APIs, parsed text, foreign interfaces, and other inputs outside
the language's trusted type system.

- Validate and parse at the boundary
- Define the runtime contract near the type it protects when practical
- Give the contract a blunt name
- Use the contract at storage, network, parsing, or public API boundaries
- Convert external representations into trusted domain shapes instead of leaking raw technical types upward
- After validation, pass trusted values inward
- Keep parse, assert, and cast-like helpers literal and easy to discover
- After boundary validation, internal code should trust the validated contract
- Do not repeat defensive validation inside the trusted core without a contract reason

---

## Control flow

Control flow should read top-down and feel predictable. A function body should
stay at one level of intent: state the steps, then place or delegate their
lower-level implementation below.

Prefer:

- Use early return. Sometimes this is cleaner:
    - single `if`/`else`
    - `?` `:`
    - avoid `return;` or `continue;` if entire scope can be written in 2 lines
- Direct `if` and `switch`
- Explicit loops when data shape is simple
- Small public methods with private helpers below
- Local branching when the case set is still compact

---

## D, when applicable

- Map module names directly to paths and let each module present one clear owner or contract family
- D declarations are public by default; mark implementation helpers `private` and keep the public module surface deliberate
- Prefer selective imports from the real owner; use local imports for genuinely local dependencies and `public import` only for an intentional facade
- Keep `version(...)` branches inside narrow platform adapters rather than scattering platform policy through ordinary modules
- Prefer `struct` for values, configuration, events, protocol data, and handles; use `class` when identity, reference semantics, or polymorphism is genuinely useful
- Use `const`, `immutable`, `ref`, and `scope` to state ownership and lifetime where they materially clarify the contract
- Treat `T[]` as a borrowed slice: slicing does not copy, appending may relocate, and crossing thread, callback, or foreign boundaries requires an explicit lifetime owner
- Use `.dup` for an owned mutable copy and `.idup` for owned immutable data
- Remember that `string` is immutable UTF-8 bytes; do not confuse byte indexing with characters or user-perceived text
- Use `scope(exit)`, `scope(failure)`, and RAII for local resource cleanup; keep ownership explicit and avoid hidden blocking work in destructors
- Use `final switch` for closed enum domains; use an ordinary `switch` with explicit fallback for open or externally sourced values
- Prefer `@safe` for ordinary code. Keep `@trusted` wrappers tiny and require them to establish a safe pointer, length, alignment, lifetime, and ownership contract
- Add `pure`, `nothrow`, and `@nogc` when they express a real boundary or execution requirement, not as decoration
- Do not allocate through the GC, throw, log, block, or acquire arbitrary locks inside realtime paths, C callbacks, or other `@nogc nothrow` boundaries
- Keep `extern(C)` and platform bindings narrow. Translate foreign representations once, then expose a D-shaped capability inward
- Use templates, `static foreach`, UDAs, and compile-time evaluation only when they remove stable boilerplate without hiding runtime ownership or flow
- Use built-in `unittest` blocks for focused module behavior when the project permits new tests

For BetterC:

- Isolate `-betterC` code in low-level modules with an explicit boundary to the normal D host
- Keep druntime, GC use, exceptions, and hidden allocation out of that boundary; prefer plain structs, fixed arrays, pointers with explicit lengths, and explicit status results
- Use a narrow `extern(C) nothrow @nogc` surface when the core must remain callable from other hosts
- Let ordinary host code use normal D facilities where they improve clarity; do not spread BetterC constraints into higher levels without a measured reason

---

## TypeScript, when applicable

- Use most modern language syntax targeting `next` platform
- Prefer `interface` for ordinary object shapes
- Prefer `type` for unions, mapped types, callable shapes, and composition of existing shapes
- Prefer discriminated unions with string literals for closed domains
- Prefer `unknown` at untrusted boundaries and narrow deliberately
- Do not use `any`
- Use `delete` over object spread when removing a property
- Prefer array spread (`[...arr]`) over `Array.from(...)`
- Use explicit named types even for small interfaces especially in function signatures
- Always specify function return type
- Use numeric separators in non-trivial numeric literals (`65_535`, `0xaa_ff`)
- `throw` is unnecessary after a call to a function that returns `never`
- Validate numeric requirements at the boundary; do not repeatedly normalize trusted values with defensive `floor`, `min`, `max`, or `NaN` fixups
- Inside trusted code, check only failures allowed by the contract, such as an expected out-of-bounds request
- Keep objects valid at all times; reject operations that would create invalid state
- Construct plain objects only in valid states
- Prefer `satisfies` when checking object literals while preserving useful inference
- Do not use anonymous object type literals; resolve them to named types
- Mark domain fields and collections `readonly` by default
- Strongly prefer member access with dot over object spread
- Use `!` only when a local invariant already guarantees presence and that invariant is visible nearby
- Let contract and proven invariants drive control flow; do not add runtime branches that exist only to satisfy TypeScript narrowing
- Prefer strict owner methods like `get(...)` over scattered non-null assertions
- When runtime semantics guarantee an invariant but the type system cannot prove it, encode that fact explicitly (`!`, assertion function, or strict owner method) near the proof site
- Use `as` only when the invariant cannot be expressed cleanly and the reasoning is local
- Use optional chaining when absence is truly part of the contract, not as a substitute for ownership clarity
- Modern TypeScript narrows `this.field` after guards; do not alias class fields only for narrowing
- Alias class fields to locals only to capture pre-mutation state or avoid repeated expensive work
- Use `??` for nullish defaulting
- Use assertion functions and type guards to narrow real runtime facts, not to paper over unclear design
- Use `async` / `await` over `.then()` / `.catch()` chains for normal control flow
- Do not use wildcard exports or barrel modules that only re-export; import from the real owner
- Write interface methods as function-valued properties; use ordinary method syntax elsewhere
- Promises returned to user code must have explicit `await` to improve stack traces for debugging, otherwise prefix with `void`
- For get/set properties with same name as backing field use `#field`
- A `switch` should always have a `default` case, typically rejecting an impossible state through the project's invariant helper

---

## Data shapes and helper layer

Use types to make shapes readable and ownership obvious.

- Use plain interfaces and type aliases for domain shapes
- Keep domain objects simple and inspectable
- Keep identity fields literal and obvious
- Keep domain shapes distinct from lower-level transport, persistence, and platform representations
- Prefer nested composed structures for grouping related small structures; example: `theme.panel.border.color` over `panelBorderColor`

Prefer plain, inspectable data objects at boundaries:

- Parsed payloads
- Transport messages
- Persisted rows
- AST nodes
- Emitted events

Do not hide simple boundary data behind behavior-heavy wrappers unless the wrapper truly owns invariants or lifecycle.

### Repeated patterns to extract

When refactoring, actively look for repeated operational shapes and pull them into one sharper mechanism.

Common examples:

- Require-get from a map, table, registry, or cache
- Get-or-create in a state owner
- Remove-if-empty or prune-if-unused
- Validate-then-mutate flows with the same repair steps
- Repeated binding, subscription, or disposal ceremony

This applies at two levels:

- In the helper layer, when the pattern is truly low-level and reused across unrelated domains
- Inside a domain owner, when the pattern is part of one domain's semantics and should stay near that owner

Prefer:

- One blunt helper or owner method that preserves the full semantics, including validation and failure behavior
- Extracting the invariant shape even when the duplicated code is only a few lines, if the repetition is real
- Naming the mechanism after what it guarantees, not after the syntax it happens to use

Avoid:

- Open-coding the same lookup-create-validate pattern repeatedly because each copy feels too small
- Extracting only syntax while leaving each caller to re-decide error handling, pruning, or lifecycle policy
- Pushing a domain-specific repetition into a global helper when the real seam is a small domain object

---

## UI, DOM, and CSS, when applicable

UI should stay explicit and narrowly responsible.

### UI rules

- UI owns presentation and local interaction only
- UI entrypoints coordinate presentation in UI vocabulary and delegate domain or technical work
- Build DOM explicitly through focused helpers or tiny wrappers
- Views should expose an `element` and keep DOM ownership local
- Keep DOM mutation incremental and precise
- Use small adapters when one view can target multiple shapes
- Keep translation lookup at the UI edge

### Split when UI gets too heavy

If a view starts handling too many of these at once, split it:

- Rendering
- Parsing
- Query semantics
- Creation rules
- Focus restoration
- Selection state
- Domain mutation
- Persistence or transport calls

DOM event handlers should state the interaction intent and delegate quickly to
named methods or collaborators rather than implementing domain or transport
mechanics inline.

### Avoid

- Hidden template magic for simple components
- Browser code that owns persistence or backend orchestration
- Giant UI controllers that mix rendering, data access, and domain rules
- Views that quietly become parser owners, store owners, orchestrators, and network clients all at once

### CSS / HTML defaults

- Prefer reasonable selectors, including child selectors where appropriate
- Do not add classes when a stable parent selector already makes selection obvious
- Keep CSS entry imports in one explicit application entrypoint rather than scattering them through unrelated logic modules
- Keep styling ownership calm and local
- Prefer structure and naming that make the DOM easy to inspect

### Canvas / theming

For canvas-style UI primitives:

- Treat them like DOM views: small owners with clear responsibility
- Move generic list, button, or layout primitives into shared UI folders only after real repeated pressure
- Default style values should come from theme objects
- Call sites should override only the fields they actually need

Theming rules:

- Style ownership belongs in theme definitions, not component constructors
- Each styleable component should have one fixed style key and optional `role`
- Theme component styles should use `default` plus optional role patches
- Role patches should compose from generic to specific
- Component code should not expose ad hoc `setStyle(...)`
- Runtime styling entry should be role changes
- Base component infrastructure should own theme subscriptions and resolved style state
- Derived components should only react to style or role lifecycle hooks
- When a component owns child components, derive child roles from the parent role rather than hardcoding child variants

---

## Errors

- Failures are part of the function contract
- Fail fast through the language's normal failure mechanism as soon as an invariant is known to be broken
- Do not defensively return a missing value or perform a no-op when the contract requires failure
- Catch, convert, or recover only where real handling behavior can take place
- Lower-level code reports failures in its own contract; the level that owns the outcome decides retry, recovery, fallback, or presentation
- Use the project's error taxonomy when one exists. A useful split is:
    - `internal` for a broken invariant, impossible state, or programmer error
    - `invalid` for an operation that is not valid now
    - `contract` for external data violating a boundary contract
    - `io` for filesystem, network, OS, or hardware failure
- Use human-readable friendly codes for error messages

---

## Testing

Keep testing short, explicit, and scenario-driven.

Rules:

- Keep test harnesses small
- Colocate tests near the module they exercise when practical
- Aggregate suites explicitly
- Test each unit at its own contract level; do not make workflow tests depend on lower-level adapter mechanics
- Build realistic starting state
- Assert resulting state, side effects, emitted events, and error text when contractual
- Prefer minimal mocking

### Preferred test shape

1. build a realistic starting state
2. perform one operation
3. assert resulting state
4. assert related side effects
5. assert failure behavior for invalid operations

Avoid giant fake frameworks and tests that only assert return values while ignoring contractual side effects.

---

## Refactoring and working method

This codebase should improve through repeated focused passes, not giant redesigns.

### Refactor toward general composition

A core habit in the earlier system is to refactor specific workflow code into smaller general-purpose mechanisms, then rebuild the feature by composing those mechanisms.

This does not mean speculative mega-abstractions.
It means:

- Start with concrete feature code
- Identify the invariant mechanism and the varying policy
- Extract the invariant into a small owner with blunt verbs
- Extract a lower-level unit when doing so lets its caller return to one clear vocabulary
- Represent variation as parameters, small interfaces, runtime contracts, adapters, or data
- Let feature code become high-level composition, wiring, and domain naming

Prefer:

- One good general `Table`, `Builder`, `Store`, `Observable`, `Rpc`, or helper primitive
- Thin feature-specific composition around those pieces
- Orthogonal units that combine cleanly without knowing product policy
- Refactors that move commonality downward and leave specialized meaning at the edges

Avoid:

- Parallel families of near-duplicate helpers, services, or models
- Inheritance trees created only to share a few steps
- "general" abstractions that are really one feature with flags
- Helpers whose reuse is textual only, not conceptual

The target is not maximal generality.
The target is a small set of sharp reusable mechanisms with obvious owners, and larger behaviors assembled from them.

### Refactor present code

Refactoring should answer today's pressure in the code, not hypothetical future pressure.

Bad design questions:

- "What if we need five more variants later?"
- "What if this becomes a platform abstraction one day?"
- "What if another subsystem wants this shape later?"

Better refactoring questions:

- "What is duplicated right now?"
- "What is hard to trace right now?"
- "What owner is unclear right now?"
- "What is the source of truth right now?"
- "What state is functionally dependent on other state right now?"
- "What branching or API surface can be removed right now?"

Prefer:

- Refactors that reduce code, branches, and concepts in the current diff
- Abstractions justified by present duplication or present pressure
- Smaller public surfaces after the refactor than before it
- One primary owner for each mutable fact
- Deriving dependent state when the derivation is cheap and local
- Denormalized state only when it buys real clarity or runtime behavior, with one obvious repair point
- Solving one real seam cleanly instead of preparing for several imaginary ones

Avoid:

- "what if" driven abstractions
- Adding extension points before there is a second real caller or second real policy
- Widening a module's scope while claiming to simplify it
- Storing the same fact in several mutable places when one owner can carry it and the others can follow
- Denormalized state that has no single repair step or can drift silently
- Carrying extra options, hooks, or types that no current code needs

### Practical questions

Ask repeatedly:

- Is the owner obvious?
- Does each function, class, interface, module, and file use one vocabulary and abstraction level?
- Does the call path step from intent toward mechanics without interleaving them?
- Has technical detail leaked upward or policy leaked downward?
- Is there reusable mechanism hiding behind these special cases?
- Is mutation clearly owned?
- Is validation happening once, near the edge?
- Would a small helper calm the flow?
- Would a direct branch be clearer than a framework pattern here?
- Are imports pointing at the real owner?

### Refactor heuristics

- If a class mixes workflow and transport or storage detail, push detail down
- If one method mutates state and repairs indexes in several places, centralize that mutation
- If callers import behavior through an unrelated file, fix ownership instead of adding pass-through exports
- If a file reads like a registry of special cases, check whether a direct `switch` plus helpers is cleaner
- If UI code starts deciding backend policy, move the decision to the feature or domain owner
- If a lower-level module needs app decisions, move the seam upward
- If a coordinator alternates between workflow calls and technical mechanics, extract the mechanics behind a lower-level capability
- If an adapter decides workflow, retries, or presentation policy, pull that decision into the level that owns the outcome
- If several specialized modules differ mainly in naming, one data shape, or one policy step, extract the invariant mechanism and compose the difference at the edge
- Prefer one sharp general primitive plus composition over another near-duplicate wrapper
- If a helper exists only to make one call site shorter, reconsider whether it earns its existence

---

## Code syntax and style rules

- Follow the project or language formatter; where none exists, use 4-space indentation
- Use blank lines to separate conceptual steps, not every line
- Keep comments very rare, only for non-obvious operations or invariants
    - remove comments that only narrate mechanics
- Code should serve as documentation
- Wrap long expressions at semantic boundaries
- Keep imports direct and explicit
- Magic numbers are fine directly where used; do not create a constant unless it is reused or its name carries domain meaning
