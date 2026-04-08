You are performing a deep, systematic optimization audit of this codebase. Your standard is
"would this impress a systems programmer who values correctness, efficiency, and simplicity
above all else?" Every change must be justified by measurable improvement or provable
correctness — not style preference.

Work through the following passes in order. Complete each pass fully before starting the next.
After all passes, provide a consolidated summary of every change made and why.

---

## PASS 1 — RESOURCE LIFECYCLE AUDIT

Goal: Eliminate leaks, dangling references, and unnecessary retention.

- Find every subscription (Combine, NotificationCenter, KVO, delegates) and verify it is
  cancelled/removed at the correct lifecycle point. Flag any stored in non-cancellable locals.
- Find every closure and verify capture semantics: [weak self] where a retain cycle is possible,
  [unowned self] only where lifetime is guaranteed. Correct any that are wrong.
- Identify any timers, DispatchWorkItems, or background tasks that are not explicitly invalidated
  on deinit or view disappearance.
- Find any cache or buffer with no eviction policy. Add size bounds or TTL where missing.
- Look for repeated allocation inside hot loops (polling callbacks, render loops, packet handlers).
  Hoist or pool any allocation that can be reused across iterations.

---

## PASS 2 — CONCURRENCY CORRECTNESS

Goal: No data races, no unnecessary serialization, no priority inversion.

- Identify every shared mutable state. Verify it is protected by a single consistent mechanism
  (actor, serial queue, lock, or atomic). Flag any state accessed from multiple contexts without
  protection.
- Find every DispatchQueue.main.async and evaluate whether it is truly necessary. Remove any
  that serialize work that could run off the main thread.
- Identify any async work blocked by a sync call (DispatchQueue.sync, semaphore.wait,
  group.wait) on the main thread. This is always a correctness hazard.
- Check for priority inversion: high-priority work waiting on a default/background queue.
- Verify that all Combine pipelines use .receive(on:) only where the subscriber requires it,
  not defensively everywhere.

---

## PASS 3 — CPU EFFICIENCY

Goal: Do less work, do it less often, do it cheaper.

- Profile the polling/tick path (the highest-frequency code path). Every allocation, copy,
  and branch in this path has compounded cost. Eliminate anything that is not strictly necessary.
- Find every computed property that performs non-trivial work and is called more than once per
  update cycle. Cache results where the inputs have not changed.
- Identify repeated string formatting, date formatting, or number formatting. NSFormatters and
  their Swift equivalents are expensive to instantiate — verify they are created once and reused.
- Find any O(n²) or worse algorithm operating on collections that grow with usage. Replace with
  appropriate data structures (Set for membership tests, sorted structures for range queries).
- Identify redundant observations: multiple subscribers reading the same upstream value and
  each doing their own transformation. Consolidate into a single shared publisher where possible.
- Remove any defensive polling or "just in case" refresh calls that could be replaced with
  event-driven updates.

---

## PASS 4 — MEMORY FOOTPRINT

Goal: Use the minimum memory required, release it as soon as possible.

- Find any collection that grows unbounded over time (history buffers, log arrays, event queues).
  Apply a fixed-size ring buffer or sliding window where appropriate.
- Identify large value types (structs with many fields or nested arrays) copied frequently.
  Evaluate whether reference semantics (class or actor) would reduce copying overhead.
- Find any lazy property or singleton that loads a large resource eagerly or never releases it.
  Apply demand-loading and explicit teardown where the resource is not always needed.
- Check for duplicate data: the same information stored in multiple representations
  simultaneously. Pick one canonical form and derive the others on demand.
- Evaluate image and media assets: are they decoded at display size or at source size?
  Apply downsampling where the display size is smaller than the asset.

---

## PASS 5 — DESIGN PATTERN CORRECTNESS

Goal: Code should express intent clearly; patterns should reduce complexity, not add ceremony.

- For every abstraction layer (protocol, wrapper type, coordinator, factory): verify it is
  justified by at least two concrete implementations, a testability requirement, or a clear
  inversion-of-control boundary. Delete any abstraction that exists for its own sake.
- For every singleton: verify it must be a singleton (shared hardware resource, global config).
  If it exists for convenience, replace it with dependency injection.
- For every delegate/callback pattern: evaluate whether a Combine publisher or async sequence
  would reduce state management burden at the call site.
- Verify the separation of concerns between modules: no UI logic in the model layer, no
  business logic in the view layer, no I/O in the domain layer.
- Find any function longer than ~40 lines. Each is a candidate for decomposition — but only
  decompose if the extracted unit has a clear, single responsibility with a name that
  communicates intent without requiring a comment.

---

## PASS 6 — DEAD CODE & COMPLEXITY REMOVAL

Goal: The best code is code that doesn't exist.

- Remove any unused imports, symbols, functions, types, and files. Confirm with a grep/LSP
  reference check before deleting.
- Remove any feature flag, compatibility shim, or migration path whose condition is always true
  or always false in the current codebase.
- Flatten any unnecessary indirection: a function that does nothing but call another function
  with the same arguments, a type that wraps another type without adding behaviour.
- Remove defensive nil-checks and guard statements around values that cannot be nil given
  their declaration. Remove force-unwraps on values that can be nil — replace with proper
  handling.
- Simplify any boolean expression that can be written more directly. Remove double-negation.
  Collapse nested ifs with the same condition.

---

## PASS 7 — CORRECTNESS VERIFICATION

Goal: Changes must not introduce regressions.

- After all changes, run the full test suite. All tests must pass.
- For any changed logic that had no test coverage, add a minimal test that would catch a
  regression in the specific behaviour that was changed.
- Review the diff holistically: are there any changes that alter observable behaviour in a
  way not covered by the above passes? If so, document them explicitly.

---

## OUTPUT FORMAT

After all passes, provide:

1. **Changes Made** — grouped by pass, each entry: file:line, what changed, why (one sentence).
2. **Removed** — list of deleted functions/types/files with justification.
3. **Not Changed** — any area you evaluated and deliberately left alone, with rationale.
4. **Remaining Concerns** — issues found but not fixed (requires architectural decision,
   out of scope, needs profiling data to confirm).

Do not make changes that are not justified by the criteria above. Prefer fewer, higher-confidence
changes over many speculative ones. When in doubt, report rather than change.
