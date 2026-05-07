Great question. Short version: we keep the core as Signal<T> on purpose, and handle “multiple values” at the edges by mapping them into a single payload object (a record/tuple) rather than using a variadic type pack. Here’s why—and how to deal with RBX signals that are variadic.

⸻

Why not Signal<T...>?

1) Composability explodes with type packs

Most operators (map, filter, merge, zip, seq, withLatest, scan, etc.) are far easier and safer when they operate on a single, stable payload type. With variadics you immediately run into:

* Merging: what’s the type of merge(Signal<A...>, Signal<B...>) when the packs differ?
* Zipping/Sequencing: you’d have to build nested packs ((A..., B...)) and keep them aligned across steps.
* FlatMap: (T...) -> Signal<U...> is hard to type and reason about across many operators.
* Distinctness/Equality: comparing “packs” is ill-defined unless you freeze them into a value.

2) Luau’s varargs are easy to drop accidentally

Passing multiple returns through layers of functions will often silently discard tail values unless every function is written to preserve varargs. One forgotten wrapper and you’ve lost data. A single value avoids this footgun.

3) Records/tuples are self-documenting

A structured payload like { keyCode = ..., isRepeat = ... } is:

* Named (readable),
* Extensible (add fields later without breaking the call sites),
* Comparable (you can define equality for stores and scans),
* Serializable (for net/logging/replay).

4) Tooling & typing stay predictable

Your IDE, lint rules, and the rest of the engine (store, rule, fsm) benefit from a consistent “one payload value” rule. It keeps generic signatures simple and inference robust.

⸻

So how do we handle variadics from Roblox signals?

At the boundary, convert them to a single payload value with sig.ofRBX’s map function (or a tiny helper):

-- Example: UserInputService.InputBegan(io, processed)
type InputBeganPayload = { io: InputObject, processed: boolean }
local InputBegan: Signal<InputBeganPayload> =
  sig.ofRBX(UIS.InputBegan, function(io, processed)
    return { io = io, processed = processed }
  end)

Or map to a typed tuple-in-a-record:

type DragDelta = { from: Vector2, to: Vector2 }
local DragMoves: Signal<DragDelta> = PointerMove:map(function(pos)
  return { from = lastPos, to = pos }
end)

If you really want an array-like payload:

local function packToArray(...)
  local t = table.pack(...)
  t.n = nil          -- optional: remove 'n' to be plain array
  return t :: {any}
end
local AnyRBX: Signal<{any}> = sig.ofRBX(SomeRBXSignal, packToArray)

⸻

When do tuples still make sense?

You can absolutely define T as a tuple type inside a record:

type Hit = { point: Vector3, normal: Vector3, material: Enum.Material }
-- Still a single value (a record), but carries multiple fields.

This keeps the engine’s contract (Signal<T>) intact while letting you carry multiple data points per event.

⸻

Practical patterns to adopt

* Always name your payload. Prefer { field1 = ..., field2 = ... } over raw tuples. Your future self will thank you.
* Normalize early. Map RBXScriptSignals into your own typed payloads at the boundary (sig.ofRBX), then compose.
* Keep Signal<void> for “moment-only” events. Timers, “clicked”, “done loading”—no data, just the fact.

⸻

Could we support Signal<T...> anyway?

We could, but it complicates every operator’s type and implementation, and makes mixed compositions brittle. The core stays cleaner and more reliable with Signal<T>. If a particular adapter really wants to preserve raw varargs, provide a thin wrapper that immediately packs them into a single value before entering the rest of the pipeline.

⸻

TL;DR

* Core engine: Signal<T> (single payload) → simple, safe, composable.
* Variadic RBX signals: map once at the edge into a structured payload.
* You don’t lose expressiveness; you gain readability, stability, and better tooling.
