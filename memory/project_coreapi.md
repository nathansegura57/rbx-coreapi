---
name: CoreAPI Project Overview
description: Luau kernel library with 9 modules — implementation status, dependency order, and key constraints
type: project
---

Full rewrite of a Luau kernel library (Roblox context). All source files deleted; implementation starts from scratch.

Output goes in `src/`. Documentation goes in `docs/`. Specs are authoritative in `specs/`.

**Implementation order (dependency chain):**
1. ErrorHandler (no deps)
2. Connection (needs ErrorHandler)
3. Scheduler (needs ErrorHandler, Connection)
4. Context (needs ErrorHandler, Connection, Scheduler)
5. Signal (needs ErrorHandler, Connection, Scheduler)
6. Store (needs ErrorHandler, Connection, Scheduler, Signal)
7. Task (needs ErrorHandler, Connection, Scheduler)
8. Rule (needs all above)
9. FSM (needs all above)
10. docs/ (after all modules)

**Why:** CLAUDE.md mandates reading specs before writing; implement one module at a time; no invented APIs.

**How to apply:** Always implement in the order above. Do not add APIs not in the spec. Stop and ask if behavior is ambiguous.
