--!strict

export type RulePolicy = {
	priority:            number?,
	cooldown:            number?,
	debounce:            number?,
	throttle:            number?,
	once:                boolean?,
	recheckBeforeEffect: boolean?,
	cancelIfGuardFlips:  boolean?,
	concurrency:         ("merge" | "switch" | "exhaust" | "concat")?,
	capacity:            number?,
	queue:               ("drop" | "latest" | "fifo")?,
	errors:              ("propagate" | "swallow" | "retry")?,
	retry:               { count: number, backoff: "fixed" | "expo", base: number, jitter: number? }?,
	trace:               boolean?,
	tag:                 string?,
	admitPhase:          ("immediate" | "endOfFrame")?,
}

-- Rule: a configured reaction bound to a scope.
-- :when() replaces :if()  — "if"  is a Lua reserved keyword.
-- :run()  replaces :do()  — "do"  is a Lua reserved keyword.
-- Every builder method returns the same Rule for fluent chaining.
export type Rule = {
	on:      (self: Rule, signal: any) -> Rule,
	when:    (self: Rule, guard: any) -> Rule,
	run:     (self: Rule, effect: (context: any, payload: any?, tools: any?) -> any?) -> Rule,
	policy:  (self: Rule, opts: RulePolicy) -> Rule,
	attach:  (self: Rule, scope: any) -> Rule,
	enable:  (self: Rule) -> Rule,
	disable: (self: Rule) -> Rule,
	dispose: (self: Rule) -> (),
	name:    (self: Rule) -> string?,
}

return nil

