# CLAUDE.md

Follow the specifications in `specs/` exactly.

Read all specification files before making changes.

Implementation behavior, naming, lifecycle semantics, scheduling semantics, error semantics, cancellation semantics, and typing semantics are defined entirely by the specification documents.

Do not infer behavior that is not explicitly specified.

Do not preserve legacy behavior unless the specifications explicitly require it.

## Specification Files

Read these in dependency order:

```text
specs/00_REFERENCES.md
specs/00_LUAU_PRACTICES.md

specs/01_CONNECTION.md
specs/02_ERROR_HANDLER.md
specs/03_SCHEDULER.md
specs/04_CONTEXT.md
specs/05_SIGNAL.md
specs/06_STORE.md
specs/07_TASK.md
specs/08_RULE.md
specs/09_FSM.md

specs/10_DOCUMENTATION_REQUIREMENTS.md
specs/11_IMPLEMENTATION_CHECKLIST.md
```

## Implementation Constraints

Do not:

- invent APIs
- rename APIs
- add convenience overloads
- add aliases
- add hidden behavior
- add implicit scheduler behavior
- add undocumented mutation
- add undocumented recursion handling
- add undocumented async behavior
- add undocumented cancellation behavior

If implementation details are ambiguous, stop and ask for clarification instead of inventing behavior.

## Deliverables

When implementing:

1. Implement exactly one module at a time.
2. Keep implementation and tests aligned with the specs.
3. Validate all edge cases described in the specifications.
4. Keep public typing exact.
5. Ensure deterministic lifecycle cleanup.
6. Ensure no scheduler leaks.
7. Ensure no connection leaks.
8. Ensure no retained references after disposal.
