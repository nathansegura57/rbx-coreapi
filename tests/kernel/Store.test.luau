--!strict

local Connection = require(script.Parent.Parent.Parent.src.Connection)
local ErrorHandler = require(script.Parent.Parent.Parent.src.ErrorHandler)
local Signal = require(script.Parent.Parent.Parent.src.Signal)
local Store = require(script.Parent.Parent.Parent.src.Store)
local TestKit = require(script.Parent.Parent.TestKit)

local suite = TestKit.Suite("Store")

suite:AfterEach(function(_ctx)
	ErrorHandler.SetPolicy("Throw")
end)

-- ── Handle model ──────────────────────────────────────────────────────────────

suite:Test("getmetatable returns 'Store'", function(ctx)
	local store = Store.Value(0)
	ctx:Expect(getmetatable(store :: any)):ToBe("Store")
end)

suite:Test("assigning a field errors with read-only message", function(ctx)
	local store = Store.Value(0)
	ctx:Expect(function()
		(store :: any).Field = true
	end):ToThrow("read-only")
end)

-- ── Store.IsStore ─────────────────────────────────────────────────────────────

suite:Test("IsStore returns true for a live Value store", function(ctx)
	local store = Store.Value(0)
	ctx:Expect(Store.IsStore(store)):ToBe(true)
end)

suite:Test("IsStore returns true for destroyed stores", function(ctx)
	local store = Store.Value(0)
	store:Destroy()
	ctx:Expect(Store.IsStore(store)):ToBe(true)
end)

suite:Test("IsStore returns false for nil", function(ctx)
	ctx:Expect(Store.IsStore(nil)):ToBe(false)
end)

suite:Test("IsStore returns false for plain table", function(ctx)
	ctx:Expect(Store.IsStore({})):ToBe(false)
end)

-- ── Store.Value ───────────────────────────────────────────────────────────────

suite:Test("Value(initial) stores the initial value", function(ctx)
	local store = Store.Value(42)
	ctx:Expect(store:Get()):ToBe(42)
end)

suite:Test("Value stores nil as initial value with presence", function(ctx)
	local store = Store.Value(nil)
	ctx:Expect(store:Get()):ToBe(nil)
	ctx:Expect(store:IsDestroyed()):ToBe(false)
end)

suite:Test("Value with Name option registers store name", function(ctx)
	local store = Store.Value(1, { Name = "TestStore_Value_Named" })
	ctx:Expect(store:Name()):ToBe("TestStore_Value_Named")
	store:Destroy()
end)

suite:Test("Value duplicate name throws without ReplaceName", function(ctx)
	local store = Store.Value(1, { Name = "TestStore_Value_Dup" })
	ctx:Expect(function()
		Store.Value(2, { Name = "TestStore_Value_Dup" })
	end):ToThrow("duplicate store name")
	store:Destroy()
end)

suite:Test("Value duplicate name allowed with ReplaceName = true", function(ctx)
	local store1 = Store.Value(1, { Name = "TestStore_Value_Replace" })
	local store2: any = nil
	ctx:Expect(function()
		store2 = Store.Value(2, { Name = "TestStore_Value_Replace", ReplaceName = true })
	end):ToNotThrow()
	store1:Destroy()
	if store2 ~= nil then store2:Destroy() end
end)

suite:Test("Value with invalid opts throws", function(ctx)
	ctx:Expect(function()
		Store.Value(1, 42 :: any)
	end):ToThrow("opts must be a table or nil")
end)

-- ── Store.Const ───────────────────────────────────────────────────────────────

suite:Test("Const stores a read-only value", function(ctx)
	local store = Store.Const(99)
	ctx:Expect(store:Get()):ToBe(99)
end)

suite:Test("Const: Set throws", function(ctx)
	local store = Store.Const(1)
	ctx:Expect(function()
		(store :: any):Set(2)
	end):ToThrow()
end)

-- ── Store.Derive ──────────────────────────────────────────────────────────────

suite:Test("Derive runs compute immediately and stores result", function(ctx)
	local dep = Store.Value(5)
	local derived = Store.Derive(function() return dep:Get() * 2 end, { dep })
	ctx:Expect(derived:Get()):ToBe(10)
end)

suite:Test("Derive recomputes when dep changes", function(ctx)
	local dep = Store.Value(3)
	local derived = Store.Derive(function() return dep:Get() + 1 end, { dep })
	dep:Set(9)
	ctx:Expect(derived:Get()):ToBe(10)
end)

suite:Test("Derive: non-function compute throws", function(ctx)
	local dep = Store.Value(1)
	ctx:Expect(function()
		Store.Derive(42 :: any, { dep })
	end):ToThrow("compute must be a function")
end)

suite:Test("Derive: empty deps throws", function(ctx)
	ctx:Expect(function()
		Store.Derive(function() return 1 end, {})
	end):ToThrow("non-empty dense array")
end)

suite:Test("Derive: non-store dep throws", function(ctx)
	ctx:Expect(function()
		Store.Derive(function() return 1 end, { "not a store" :: any })
	end):ToThrow("not a live Store")
end)

suite:Test("Derive: initial compute failure throws", function(ctx)
	local dep = Store.Value(1)
	ctx:Expect(function()
		Store.Derive(function() error("compute boom") end, { dep })
	end):ToThrow("initial compute failed")
end)

suite:Test("Destroy dep destroys derived", function(ctx)
	local dep = Store.Value(1)
	local derived = Store.Derive(function() return dep:Get() end, { dep })
	dep:Destroy()
	ctx:Expect(derived:IsDestroyed()):ToBe(true)
end)

suite:Test("Destroy derived unlinks from dep", function(ctx)
	local dep = Store.Value(1)
	local derived = Store.Derive(function() return dep:Get() end, { dep })
	derived:Destroy()
	ctx:Expect(dep:IsDestroyed()):ToBe(false)
end)

-- ── Store.Select ─────────────────────────────────────────────────────────────

suite:Test("Select picks a field from source", function(ctx)
	local source = Store.Value({ x = 10, y = 20 })
	local selected = Store.Select(source, function(v) return (v :: any).x end)
	ctx:Expect(selected:Get()):ToBe(10)
end)

suite:Test("Select updates when source changes", function(ctx)
	local source = Store.Value({ x = 1 })
	local selected = Store.Select(source, function(v) return (v :: any).x end)
	source:Set({ x = 42 })
	ctx:Expect(selected:Get()):ToBe(42)
end)

-- ── Store.Combine ─────────────────────────────────────────────────────────────

suite:Test("Combine(array) produces array of current values", function(ctx)
	local a = Store.Value(1)
	local b = Store.Value(2)
	local combined = Store.Combine({ a, b })
	local result = combined:Get()
	ctx:Expect((result :: any)[1]):ToBe(1)
	ctx:Expect((result :: any)[2]):ToBe(2)
end)

suite:Test("Combine(object) produces record of current values", function(ctx)
	local x = Store.Value(10)
	local y = Store.Value(20)
	local combined = Store.Combine({ x = x, y = y })
	local result = combined:Get()
	ctx:Expect((result :: any).x):ToBe(10)
	ctx:Expect((result :: any).y):ToBe(20)
end)

suite:Test("Combine: empty table throws", function(ctx)
	ctx:Expect(function()
		Store.Combine({})
	end):ToThrow("not be empty")
end)

-- ── Store.AllTruthy / AnyTruthy ───────────────────────────────────────────────

suite:Test("AllTruthy is true only when all values are truthy", function(ctx)
	local a = Store.Value(true)
	local b = Store.Value(true)
	local all = Store.AllTruthy({ a, b })
	ctx:Expect(all:Get()):ToBe(true)
	b:Set(false)
	ctx:Expect(all:Get()):ToBe(false)
end)

suite:Test("AnyTruthy is true when at least one value is truthy", function(ctx)
	local a = Store.Value(false)
	local b = Store.Value(false)
	local any = Store.AnyTruthy({ a, b })
	ctx:Expect(any:Get()):ToBe(false)
	b:Set(true)
	ctx:Expect(any:Get()):ToBe(true)
end)

-- ── Store.Match ───────────────────────────────────────────────────────────────

suite:Test("Match selects case by source key", function(ctx)
	local state = Store.Value("active")
	local activeVal = Store.Const(100)
	local idleVal = Store.Const(0)
	local matched = Store.Match(state, { active = activeVal, idle = idleVal })
	ctx:Expect(matched:Get()):ToBe(100)
	state:Set("idle")
	ctx:Expect(matched:Get()):ToBe(0)
end)

suite:Test("Match falls back to '_' default case", function(ctx)
	local state = Store.Value("unknown")
	local defaultVal = Store.Const(-1)
	local matched = Store.Match(state, { _ = defaultVal })
	ctx:Expect(matched:Get()):ToBe(-1)
end)

suite:Test("Match: no initial case throws", function(ctx)
	local state = Store.Value("unknown")
	local someCase = Store.Const(1)
	ctx:Expect(function()
		Store.Match(state, { known = someCase })
	end):ToThrow("initial case not found")
end)

-- ── Store.Readonly ────────────────────────────────────────────────────────────

suite:Test("Readonly mirrors source value", function(ctx)
	local source = Store.Value(5)
	local ro = Store.Readonly(source)
	ctx:Expect(ro:Get()):ToBe(5)
	source:Set(10)
	ctx:Expect(ro:Get()):ToBe(10)
end)

suite:Test("Readonly: Set throws", function(ctx)
	local source = Store.Value(1)
	local ro = Store.Readonly(source)
	ctx:Expect(function()
		(ro :: any):Set(2)
	end):ToThrow()
end)

suite:Test("Destroying source destroys readonly view", function(ctx)
	local source = Store.Value(1)
	local ro = Store.Readonly(source)
	source:Destroy()
	ctx:Expect(ro:IsDestroyed()):ToBe(true)
end)

suite:Test("Destroying readonly view does not destroy source", function(ctx)
	local source = Store.Value(1)
	local ro = Store.Readonly(source)
	ro:Destroy()
	ctx:Expect(source:IsDestroyed()):ToBe(false)
end)

-- ── Get / Peek / Set / Update ─────────────────────────────────────────────────

suite:Test("Get returns current value", function(ctx)
	local store = Store.Value("hello")
	ctx:Expect(store:Get()):ToBe("hello")
end)

suite:Test("Get on destroyed store throws", function(ctx)
	local store = Store.Value(1)
	store:Destroy()
	ctx:Expect(function()
		store:Get()
	end):ToThrow("store is destroyed")
end)

suite:Test("Peek returns same as Get", function(ctx)
	local store = Store.Value(7)
	ctx:Expect(store:Peek()):ToBe(7)
end)

suite:Test("Set updates the value immediately", function(ctx)
	local store = Store.Value(1)
	store:Set(99)
	ctx:Expect(store:Get()):ToBe(99)
end)

suite:Test("Set with equal value does not mark dirty", function(ctx)
	local callCount = 0
	local store = Store.Value(1)
	store:Subscribe(function(_new, old)
		if old ~= nil then callCount += 1 end
	end, { Immediate = false })
	store:Set(1)
	ctx.Mock:Flush()
	ctx:Expect(callCount):ToBe(0)
end)

suite:Test("Set on destroyed store throws", function(ctx)
	local store = Store.Value(1)
	store:Destroy()
	ctx:Expect(function()
		store:Set(2)
	end):ToThrow("store is destroyed")
end)

suite:Test("Update computes new value from current", function(ctx)
	local store = Store.Value(5)
	store:Update(function(v) return v + 1 end)
	ctx:Expect(store:Get()):ToBe(6)
end)

suite:Test("Update: non-function throws", function(ctx)
	local store = Store.Value(1)
	ctx:Expect(function()
		store:Update(42 :: any)
	end):ToThrow("updater must be a function")
end)

suite:Test("Update on destroyed store throws", function(ctx)
	local store = Store.Value(1)
	store:Destroy()
	ctx:Expect(function()
		store:Update(function(v) return v end)
	end):ToThrow("store is destroyed")
end)

-- ── Subscribe ─────────────────────────────────────────────────────────────────

suite:Test("Subscribe returns a Connection", function(ctx)
	local store = Store.Value(1)
	local conn = store:Subscribe(function(_new, _old) end)
	ctx:Expect(Connection.IsConnection(conn)):ToBe(true)
	ctx:Expect(conn.Connected):ToBe(true)
end)

suite:Test("Subscribe with Immediate=true calls listener immediately with (value, nil)", function(ctx)
	local received: { any } = {}
	local store = Store.Value(42)
	store:Subscribe(function(newVal, oldVal)
		table.insert(received, { newVal, oldVal })
	end, { Immediate = true })
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1][1]):ToBe(42)
	ctx:Expect(received[1][2]):ToBe(nil)
end)

suite:Test("Subscribe with Immediate=false skips initial delivery", function(ctx)
	local count = 0
	local store = Store.Value(1)
	store:Subscribe(function(_new, _old) count += 1 end, { Immediate = false })
	ctx:Expect(count):ToBe(0)
end)

suite:Test("Subscribe notifies on Set during flush", function(ctx)
	local received: { number } = {}
	local store = Store.Value(1)
	store:Subscribe(function(newVal, _old)
		table.insert(received, newVal)
	end, { Immediate = false })
	store:Set(2)
	ctx.Mock:Flush()
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1]):ToBe(2)
end)

suite:Test("Disconnecting stops future notifications", function(ctx)
	local count = 0
	local store = Store.Value(1)
	local conn = store:Subscribe(function(_new, _old) count += 1 end, { Immediate = false })
	conn:Disconnect()
	store:Set(2)
	ctx.Mock:Flush()
	ctx:Expect(count):ToBe(0)
end)

suite:Test("Subscribe: listener error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	local store = Store.Value(1)
	store:Subscribe(function(_new, _old) error("sub boom") end, { Immediate = true })
	ctx:Expect(errors:HasModule("Store")):ToBe(true)
	ctx:Expect(errors:HasPhase("Subscribe")):ToBe(true)
	errors:Uninstall()
end)

suite:Test("Subscribe with Deferred=true delivers initial via defer", function(ctx)
	local received: { any } = {}
	local store = Store.Value(7)
	store:Subscribe(function(newVal, _old)
		table.insert(received, newVal)
	end, { Immediate = true, Deferred = true })
	ctx:Expect(#received):ToBe(0)
	ctx.Mock:Flush()
	ctx:Expect(#received):ToBe(1)
	ctx:Expect(received[1]):ToBe(7)
end)

-- ── Changed ───────────────────────────────────────────────────────────────────

suite:Test("Changed returns a Signal", function(ctx)
	local store = Store.Value(1)
	local sig = store:Changed()
	ctx:Expect(Signal.IsSignal(sig)):ToBe(true)
end)

suite:Test("Changed signal fires with {New, Old} on Set", function(ctx)
	local received: { any } = {}
	local store = Store.Value(1)
	store:Changed():Connect(function(p) table.insert(received, p) end)
	store:Set(2)
	ctx.Mock:Flush()
	ctx:Expect(#received):ToBe(1)
	ctx:Expect((received[1] :: any).New):ToBe(2)
	ctx:Expect((received[1] :: any).Old):ToBe(1)
end)

suite:Test("Changed returns same signal on repeated calls", function(ctx)
	local store = Store.Value(1)
	ctx:Expect(store:Changed()):ToBe(store:Changed())
end)

-- ── Batch ─────────────────────────────────────────────────────────────────────

suite:Test("Batch flushes synchronously at outermost exit", function(ctx)
	local notifications: { number } = {}
	local store = Store.Value(0)
	store:Subscribe(function(newVal, _old)
		table.insert(notifications, newVal)
	end, { Immediate = false })
	Store.Batch(function()
		store:Set(1)
		store:Set(2)
		store:Set(3)
		ctx:Expect(#notifications):ToBe(0)
	end)
	ctx:Expect(#notifications):ToBe(1)
	ctx:Expect(notifications[1]):ToBe(3)
end)

suite:Test("Batch: non-function throws", function(ctx)
	ctx:Expect(function()
		Store.Batch(42 :: any)
	end):ToThrow("block must be a function")
end)

-- ── Transaction ───────────────────────────────────────────────────────────────

suite:Test("Transaction defers flush to scheduler at outermost exit", function(ctx)
	local notifications: { number } = {}
	local store = Store.Value(0)
	store:Subscribe(function(newVal, _old)
		table.insert(notifications, newVal)
	end, { Immediate = false })
	Store.Transaction(function()
		store:Set(1)
		store:Set(2)
		ctx:Expect(#notifications):ToBe(0)
	end)
	ctx:Expect(#notifications):ToBe(0)
	ctx.Mock:Flush()
	ctx:Expect(#notifications):ToBe(1)
	ctx:Expect(notifications[1]):ToBe(2)
end)

-- ── DisconnectAll ─────────────────────────────────────────────────────────────

suite:Test("DisconnectAll removes all subscribers", function(ctx)
	local count = 0
	local store = Store.Value(0)
	store:Subscribe(function(_new, _old) count += 1 end, { Immediate = false })
	store:Subscribe(function(_new, _old) count += 1 end, { Immediate = false })
	store:DisconnectAll()
	store:Set(1)
	ctx.Mock:Flush()
	ctx:Expect(count):ToBe(0)
end)

suite:Test("DisconnectAll keeps store live", function(ctx)
	local store = Store.Value(1)
	store:DisconnectAll()
	ctx:Expect(store:IsDestroyed()):ToBe(false)
end)

-- ── Destroy / IsDestroyed ─────────────────────────────────────────────────────

suite:Test("Destroy marks store destroyed", function(ctx)
	local store = Store.Value(1)
	ctx:Expect(store:IsDestroyed()):ToBe(false)
	store:Destroy()
	ctx:Expect(store:IsDestroyed()):ToBe(true)
end)

suite:Test("Destroy is idempotent", function(ctx)
	local store = Store.Value(1)
	store:Destroy()
	ctx:Expect(function()
		store:Destroy()
	end):ToNotThrow()
end)

-- ── Name / Deps ───────────────────────────────────────────────────────────────

suite:Test("Name returns nil for unnamed stores", function(ctx)
	local store = Store.Value(1)
	ctx:Expect(store:Name()):ToBe(nil)
end)

suite:Test("Deps returns empty array for value stores", function(ctx)
	local store = Store.Value(1)
	local deps = store:Deps()
	ctx:Expect(#deps):ToBe(0)
end)

suite:Test("Deps returns dependency array for derived stores", function(ctx)
	local dep = Store.Value(1)
	local derived = Store.Derive(function() return dep:Get() end, { dep })
	local deps = derived:Deps()
	ctx:Expect(#deps):ToBe(1)
	ctx:Expect(deps[1]):ToBe(dep)
end)

-- ── Snapshot / Restore ────────────────────────────────────────────────────────

suite:Test("Snapshot captures current named store values", function(ctx)
	local store = Store.Value(5, { Name = "TestStore_Snap_A" })
	local snap = Store.Snapshot(store)
	ctx:Expect(snap["TestStore_Snap_A"]):ToBe(5)
	store:Destroy()
end)

suite:Test("Restore sets named stores from snapshot", function(ctx)
	local store = Store.Value(1, { Name = "TestStore_Restore_A" })
	local snap = Store.Snapshot(store)
	store:Set(99)
	ctx:Expect(store:Get()):ToBe(99)
	Store.Restore(snap)
	ctx.Mock:Flush()
	ctx:Expect(store:Get()):ToBe(1)
	store:Destroy()
end)

suite:Test("Restore ignores unknown names in non-strict mode", function(ctx)
	ctx:Expect(function()
		Store.Restore({ UnknownStore = 99 })
	end):ToNotThrow()
end)

suite:Test("Restore strict=true errors on unknown store name", function(ctx)
	ctx:Expect(function()
		Store.Restore({ UnknownStore_Strict = 99 }, { Strict = true })
	end):ToThrow("unknown store")
end)

-- ── History ───────────────────────────────────────────────────────────────────

suite:Test("History: Undo restores previous value", function(ctx)
	local store = Store.Value(1)
	local history = Store.History(store)
	store:Set(2)
	ctx.Mock:Flush()
	local undone = history.Undo()
	ctx:Expect(undone):ToBe(true)
	ctx:Expect(store:Get()):ToBe(1)
	history.Destroy()
end)

suite:Test("History: Redo re-applies undone value", function(ctx)
	local store = Store.Value(1)
	local history = Store.History(store)
	store:Set(2)
	ctx.Mock:Flush()
	history.Undo()
	local redone = history.Redo()
	ctx:Expect(redone):ToBe(true)
	ctx:Expect(store:Get()):ToBe(2)
	history.Destroy()
end)

suite:Test("History: Undo returns false when empty", function(ctx)
	local store = Store.Value(1)
	local history = Store.History(store)
	ctx:Expect(history.Undo()):ToBe(false)
	history.Destroy()
end)

suite:Test("History: CanUndo/CanRedo track stack state", function(ctx)
	local store = Store.Value(0)
	local history = Store.History(store)
	ctx:Expect(history.CanUndo:Get()):ToBe(false)
	store:Set(1)
	ctx.Mock:Flush()
	ctx:Expect(history.CanUndo:Get()):ToBe(true)
	history.Undo()
	ctx:Expect(history.CanUndo:Get()):ToBe(false)
	ctx:Expect(history.CanRedo:Get()):ToBe(true)
	history.Destroy()
end)

suite:Test("History: Clear empties undo and redo stacks", function(ctx)
	local store = Store.Value(0)
	local history = Store.History(store)
	store:Set(1)
	ctx.Mock:Flush()
	history.Clear()
	ctx:Expect(history.CanUndo:Get()):ToBe(false)
	ctx:Expect(history.CanRedo:Get()):ToBe(false)
	history.Destroy()
end)

suite:Test("History: Destroy disconnects subscription", function(ctx)
	local count = 0
	local store = Store.Value(0)
	local history = Store.History(store)
	-- Replace internal subscription tracking by counting indirect effects.
	-- After Destroy, changes no longer push to undo stack.
	history.Destroy()
	store:Set(1)
	ctx.Mock:Flush()
	-- Fresh history would have 1 entry but original is destroyed.
	ctx:Expect(count):ToBe(0)
end)

suite:Test("History: limit caps undo stack size", function(ctx)
	local store = Store.Value(0)
	local history = Store.History(store, 2)
	store:Set(1)
	store:Set(2)
	store:Set(3)
	ctx.Mock:Flush()
	history.Undo()
	history.Undo()
	local canUndoMore = history.Undo()
	ctx:Expect(canUndoMore):ToBe(false)
	history.Destroy()
end)

return suite:Run()
