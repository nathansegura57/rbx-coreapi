# Module Hierarchy Rules

## Core rule

Module hierarchy is information architecture.

Create the minimal number of submodules required to make the module more skimmable, intuitive, and easy to reason about.

Submodules are not a loophole for hiding messy implementation.

The parent module must still show the high-level public algorithm.

## Only standardized submodule

The only standardized child module name is:

```text
_Types
```

Use `_Types` when:

- multiple files need shared types;
- public types need clean re-exporting;
- recursive generic definitions need careful separation;
- private record types are shared across meaningful helper modules.

`_Types` must declare types directly.

It must not simply re-export types from another implementation file.

Bad:

```luau
local Runtime = require(script.Parent._Runtime)

export type Policy = Runtime.Policy
```

Good:

```luau
export type Policy = {
    Trace: boolean,
    Tag: string?,
}
```

## All other submodules are earned

No other child-module names are mandatory.

Do not follow a template.

Do not preserve a flawed current split.

Choose submodules only when they are the minimal optimal information architecture.

A child module is justified when:

- the concept has its own vocabulary;
- the concept has its own invariants;
- the concept can be understood independently;
- the concept is reused by multiple public methods;
- keeping it inline hides the parent algorithm;
- the boundary is stable.

A child module is not justified when:

- it only forwards calls;
- it has a vague name;
- it exists only to reduce line count;
- it makes the reader bounce across files for one algorithm;
- it hides the public method's control flow.

## Suspicious names

Avoid vague names such as:

```text
_Helpers
_Utils
_Common
_Shared
_Misc
_Runtime
_Core
_Manager
_Internal
```

These names are not automatically impossible, but they require exceptional justification.

If a file would be named `_Runtime`, ask what it actually owns:

- records?
- settlement?
- cancellation?
- transitions?
- replay?
- validation?
- lookup?
- destruction?
- queue admission?

Name the concept, not the fact that it is internal.

## Parent/child require paths

If a parent module requires its child:

```luau
local Types = require(script._Types)
```

If a child requires a sibling child:

```luau
local Types = require(script.Parent._Types)
```

If a child requires a Kernel sibling at the same level as the parent:

```luau
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Parent.Scheduler)
```

Example hierarchy:

```text
Kernel
├─ ErrorHandler
├─ Scheduler
└─ FSM
   ├─ _Types
   └─ _Transitions
```

Inside `FSM/_Transitions`, use:

```luau
require(script.Parent.Parent.ErrorHandler)
```

not:

```luau
require(script.Parent.ErrorHandler)
```

## Line-count guidance

Line count is a signal, not a command.

| Size | Guidance |
|---:|---|
| Under 400 lines | Usually keep one file. |
| 400–700 lines | Use strong internal sectioning. Split only if concepts are stable. |
| 700–1000 lines | Strongly consider meaningful child modules. |
| Over 1000 lines | Almost always split unless splitting would obscure one linear algorithm. |

The goal is skimmability, not arbitrary file size.
