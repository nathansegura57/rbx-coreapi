# CLAUDE.md

You are performing a final production-quality pass on the CoreAPI Kernel modules.

## Mission

Make every Kernel module beautiful, production-ready, highly declarative, skimmable, intuitive, type-friendly, and consistent with modern Luau.

This is not a cosmetic formatting pass.

This is an architecture, type-system, runtime-semantics, and information-architecture pass.

## Required reading order

Before editing, read:

1. `.claude/helpers/KERNEL_BEAUTIFICATION_STANDARD.md`
2. `.claude/helpers/LUAU_TYPE_SYSTEM_RULES.md`
3. `.claude/helpers/MODULE_HIERARCHY_RULES.md`
4. `.claude/helpers/RUNTIME_ERROR_SEMANTICS.md`
5. `.claude/helpers/FINAL_PASS_CHECKLIST.md`

Use Luau's official documentation as the source of truth for modern Luau behavior:

- https://luau.org/types/
- https://luau.org/types/basic-types/
- https://luau.org/types/table-types/
- https://luau.org/types/type-refinements/
- https://luau.org/types/generics/
- https://luau.org/syntax/
- https://luau.org/library/

## Kernel responsibility map

Each module owns exactly one primary concept.

| Module | Responsibility |
|---|---|
| ErrorHandler | Runtime failure routing and policy behavior |
| Connection | Subscription lifecycle handles |
| Scheduler | Time, deferred execution, frame stepping, and driver virtualization |
| Context | Hierarchical dependency injection and scoped ownership |
| Signal | Push-based reactive event streams |
| Store | Persistent reactive state cells and derived state |
| Task | Structured async tasks and cooperative cancellation |
| Rule | Declarative effect orchestration and admission policy |
| FSM | Hierarchical state-machine lifecycle and transitions |

Do not duplicate responsibilities across modules.

Do not create new infrastructure when an existing Kernel module already owns that concept.

## Absolute rules

- Every production Luau file must use `--!strict`.
- Prefer `unknown` over `any` at trust boundaries.
- Avoid casts unless localized and justified by validation or Luau limitations.
- Runtime callback failures route through `ErrorHandler`, unless the module's domain explicitly treats failure as result state, such as `Task` settling as `Errored`.
- Usage errors raise immediately and clearly.
- Scheduling outside `Scheduler` must not call Roblox primitives directly.
- Submodule hierarchy must be minimal and meaning-based.
- `_Types` is the only standardized child module name.
- Do not create vague child modules such as `_Helpers`, `_Utils`, `_Runtime`, `_Core`, `_Internal`, or `_Manager`.
- Parent modules must still show the high-level public algorithm. Do not turn parents into empty forwarding facades.
- Public APIs must visually dominate.
- Helper names must encode invariants.
- Do not preserve flawed current structure. Improve it.
- Ignore code comments in the existing structure.

## Final output expectation

For each module, produce production-ready Luau code and update documentation only when code/API behavior actually changes.

At the end, provide:

1. changed files list;
2. major architectural improvements;
3. type-system improvements;
4. runtime semantics fixes;
5. any remaining concerns.
