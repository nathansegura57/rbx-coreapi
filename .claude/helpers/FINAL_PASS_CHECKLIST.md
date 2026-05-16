# Final Pass Checklist

Use this checklist for every module.

## Structure

- [ ] The module's primary responsibility is clear.
- [ ] Public APIs visually dominate.
- [ ] Parent file shows high-level public algorithms.
- [ ] Submodules exist only when they improve information architecture.
- [ ] `_Types` exists when shared types are needed.
- [ ] No vague helper module names.
- [ ] No fake pass-through modules.
- [ ] No duplicate public implementations.
- [ ] Important concepts appear before implementation details.
- [ ] File length is reasonable for skimmability.

## Luau typing

- [ ] Every file uses `--!strict`.
- [ ] Public APIs are explicitly typed.
- [ ] `unknown` is used at trust boundaries.
- [ ] `any` is rare and justified.
- [ ] Exported type imports use required aliases.
- [ ] `_Types` declares types directly.
- [ ] Recursive generic types preserve exact generic arguments.
- [ ] Base/full type split is used when generic-changing methods exist.
- [ ] Enum parameters use explicit union aliases.
- [ ] Type casts are localized and justified.
- [ ] Input types are preserved when meaningful.

## Runtime behavior

- [ ] Usage errors raise directly and clearly.
- [ ] Runtime callback failures route through `ErrorHandler` unless domain-state semantics apply.
- [ ] `pcall` is not used as ad-hoc warning/swallow logic.
- [ ] Cleanup is idempotent.
- [ ] Destruction is idempotent.
- [ ] Reentrant cleanup cannot run twice.
- [ ] Scheduling uses `Scheduler`.

## Dependencies

- [ ] Existing Kernel responsibilities are reused.
- [ ] Dependencies are not excessive.
- [ ] Child module paths use `script.Parent.Parent` for Kernel siblings.
- [ ] No circular conceptual dependency exists.

## Style

- [ ] Names are long enough to communicate intent.
- [ ] Helpers encode invariants.
- [ ] Whitespace reflects conceptual hierarchy.
- [ ] Comments explain architecture or Luau limitations, not unclear code.
- [ ] The code is easy to skim top-down.

## Documentation

- [ ] Documentation matches actual API.
- [ ] Parameters, returns, errors, complex behavior, gotchas, and examples are covered.
- [ ] Design rationale is explained.
- [ ] No aspirational APIs are documented.
