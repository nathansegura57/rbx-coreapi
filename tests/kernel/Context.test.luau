--!strict

local Connection = require(script.Parent.Parent.Parent.src.Connection)
local Context = require(script.Parent.Parent.Parent.src.Context)
local ErrorHandler = require(script.Parent.Parent.Parent.src.ErrorHandler)
local TestKit = require(script.Parent.Parent.TestKit)

local suite = TestKit.Suite("Context")

suite:AfterEach(function(_ctx)
	ErrorHandler.SetPolicy("Throw")
end)

-- ── Context.Key ───────────────────────────────────────────────────────────────

suite:Test("Key(name) returns an opaque ContextKey handle", function(ctx)
	local key = Context.Key("MyKey")
	ctx:Expect(key):ToNotBe(nil)
	ctx:Expect(getmetatable(key :: any)):ToBe("ContextKey")
end)

suite:Test("Key: two keys with same name are distinct by identity", function(ctx)
	local keyA = Context.Key("Same")
	local keyB = Context.Key("Same")
	ctx:Expect(keyA):ToNotBe(keyB)
end)

suite:Test("Key: assigning a field errors with read-only message", function(ctx)
	local key = Context.Key("X")
	ctx:Expect(function()
		(key :: any).Field = true
	end):ToThrow("read-only")
end)

suite:Test("Key('') throws", function(ctx)
	ctx:Expect(function()
		Context.Key("")
	end):ToThrow("name must be a non-empty string")
end)

suite:Test("Key(nonString) throws", function(ctx)
	ctx:Expect(function()
		Context.Key(42 :: any)
	end):ToThrow("name must be a non-empty string")
end)

-- ── Context.Root ──────────────────────────────────────────────────────────────

suite:Test("Root(table) returns a live context handle", function(ctx)
	local root = Context.Root({})
	ctx:Expect(Context.IsContext(root)):ToBe(true)
	ctx:Expect(root:IsDestroyed()):ToBe(false)
end)

suite:Test("Root: getmetatable returns 'Context'", function(ctx)
	local root = Context.Root({})
	ctx:Expect(getmetatable(root :: any)):ToBe("Context")
end)

suite:Test("Root: assigning a field errors with read-only message", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		(root :: any).Field = true
	end):ToThrow("read-only")
end)

suite:Test("Root(nonTable) throws", function(ctx)
	ctx:Expect(function()
		Context.Root(42 :: any)
	end):ToThrow("values must be a table")
end)

suite:Test("Root populates initial string-keyed values", function(ctx)
	local root = Context.Root({ score = 99 })
	ctx:Expect(root:Require("score")):ToBe(99)
end)

suite:Test("Root populates initial ContextKey-keyed values", function(ctx)
	local key = Context.Key("Score")
	local root = Context.Root({ [key] = 99 })
	ctx:Expect(root:Require(key)):ToBe(99)
end)

-- ── Context.IsContext ─────────────────────────────────────────────────────────

suite:Test("IsContext returns true for a root context", function(ctx)
	local root = Context.Root({})
	ctx:Expect(Context.IsContext(root)):ToBe(true)
end)

suite:Test("IsContext returns true for a layer", function(ctx)
	local root = Context.Root({})
	local layer = root:Layer({})
	ctx:Expect(Context.IsContext(layer)):ToBe(true)
end)

suite:Test("IsContext returns true for a view", function(ctx)
	local root = Context.Root({ a = 1 })
	local view = root:View({ "a" })
	ctx:Expect(Context.IsContext(view)):ToBe(true)
end)

suite:Test("IsContext returns true for a destroyed context", function(ctx)
	local root = Context.Root({})
	root:Destroy()
	ctx:Expect(Context.IsContext(root)):ToBe(true)
end)

suite:Test("IsContext returns false for nil", function(ctx)
	ctx:Expect(Context.IsContext(nil)):ToBe(false)
end)

suite:Test("IsContext returns false for plain table", function(ctx)
	ctx:Expect(Context.IsContext({})):ToBe(false)
end)

suite:Test("IsContext returns false for non-table", function(ctx)
	ctx:Expect(Context.IsContext(42)):ToBe(false)
end)

-- ── Require ───────────────────────────────────────────────────────────────────

suite:Test("Require returns value by string key", function(ctx)
	local root = Context.Root({ name = "Alice" })
	ctx:Expect(root:Require("name")):ToBe("Alice")
end)

suite:Test("Require returns value by ContextKey", function(ctx)
	local key = Context.Key("Val")
	local root = Context.Root({ [key] = 123 })
	ctx:Expect(root:Require(key)):ToBe(123)
end)

suite:Test("Require returns nil when value is explicitly nil", function(ctx)
	local root = Context.Root({})
	root:Set("present", nil)
	ctx:Expect(root:Require("present")):ToBe(nil)
end)

suite:Test("Require climbs to parent chain", function(ctx)
	local root = Context.Root({ base = "found" })
	local child = root:Layer({})
	ctx:Expect(child:Require("base")):ToBe("found")
end)

suite:Test("Require on destroyed context throws", function(ctx)
	local root = Context.Root({})
	root:Destroy()
	ctx:Expect(function()
		root:Require("x")
	end):ToThrow("context is destroyed")
end)

suite:Test("Require with empty string key throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:Require("")
	end):ToThrow("key must be a ContextKey or non-empty string")
end)

suite:Test("Require with non-string non-key throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:Require(42 :: any)
	end):ToThrow("key must be a ContextKey or non-empty string")
end)

suite:Test("Require throws on missing key", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:Require("missing")
	end):ToThrow("missing key 'missing'")
end)

-- ── Require: lazy provider ────────────────────────────────────────────────────

suite:Test("Require resolves lazy provider on first access", function(ctx)
	local root = Context.Root({})
	local callCount = 0
	root:ProvideLazy("lazy", function(_c)
		callCount += 1
		return 42
	end)
	ctx:Expect(callCount):ToBe(0)
	local value = root:Require("lazy")
	ctx:Expect(value):ToBe(42)
	ctx:Expect(callCount):ToBe(1)
end)

suite:Test("Require caches lazy provider result on subsequent accesses", function(ctx)
	local root = Context.Root({})
	local callCount = 0
	root:ProvideLazy("lazy", function(_c)
		callCount += 1
		return "cached"
	end)
	root:Require("lazy")
	root:Require("lazy")
	ctx:Expect(callCount):ToBe(1)
end)

suite:Test("Require caches nil lazy provider result", function(ctx)
	local root = Context.Root({})
	local callCount = 0
	root:ProvideLazy("nullish", function(_c)
		callCount += 1
		return nil
	end)
	root:Require("nullish")
	root:Require("nullish")
	ctx:Expect(callCount):ToBe(1)
	ctx:Expect(root:Has("nullish")):ToBe(true)
end)

suite:Test("Require detects lazy provider cycle", function(ctx)
	local root = Context.Root({})
	root:ProvideLazy("cyclic", function(c)
		return (c :: any):Require("cyclic")
	end)
	ctx:Expect(function()
		root:Require("cyclic")
	end):ToThrow("lazy provider cycle")
end)

suite:Test("Require: lazy provider error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	local root = Context.Root({})
	root:ProvideLazy("broken", function(_c)
		error("boom")
	end)
	local ok, _ = pcall(function()
		root:Require("broken")
	end)
	ctx:Expect(ok):ToBe(false)
	ctx:Expect(errors:HasModule("Context")):ToBe(true)
	ctx:Expect(errors:HasPhase("LazyProvider")):ToBe(true)
	errors:Uninstall()
end)

suite:Test("Require: lazy provider error under non-Throw policy errors with 'failed' message", function(ctx)
	ErrorHandler.SetPolicy("Collect")
	local root = Context.Root({})
	root:ProvideLazy("broken", function(_c)
		error("boom")
	end)
	ctx:Expect(function()
		root:Require("broken")
	end):ToThrow("lazy provider failed")
	ErrorHandler.SetPolicy("Throw")
end)

-- ── Maybe ─────────────────────────────────────────────────────────────────────

suite:Test("Maybe returns nil for missing key", function(ctx)
	local root = Context.Root({})
	ctx:Expect(root:Maybe("missing")):ToBe(nil)
end)

suite:Test("Maybe returns value when present", function(ctx)
	local root = Context.Root({ x = 7 })
	ctx:Expect(root:Maybe("x")):ToBe(7)
end)

suite:Test("Maybe returns nil for invalid key instead of throwing", function(ctx)
	local root = Context.Root({})
	ctx:Expect(root:Maybe("" :: any)):ToBe(nil)
end)

suite:Test("Maybe on destroyed context throws", function(ctx)
	local root = Context.Root({})
	root:Destroy()
	ctx:Expect(function()
		root:Maybe("x")
	end):ToThrow("context is destroyed")
end)

suite:Test("Maybe returns nil for key not visible in view", function(ctx)
	local root = Context.Root({ a = 1, b = 2 })
	local view = root:View({ "a" })
	ctx:Expect(view:Maybe("b")):ToBe(nil)
end)

-- ── Has ───────────────────────────────────────────────────────────────────────

suite:Test("Has returns true for present key", function(ctx)
	local root = Context.Root({ x = 1 })
	ctx:Expect(root:Has("x")):ToBe(true)
end)

suite:Test("Has returns true when value is nil (presence vs value)", function(ctx)
	local root = Context.Root({})
	root:Set("nullish", nil)
	ctx:Expect(root:Has("nullish")):ToBe(true)
end)

suite:Test("Has returns false for absent key", function(ctx)
	local root = Context.Root({})
	ctx:Expect(root:Has("gone")):ToBe(false)
end)

suite:Test("Has returns true for unresolved lazy provider", function(ctx)
	local root = Context.Root({})
	root:ProvideLazy("lazy", function(_c)
		return 99
	end)
	ctx:Expect(root:Has("lazy")):ToBe(true)
end)

suite:Test("Has does not resolve lazy providers", function(ctx)
	local root = Context.Root({})
	local callCount = 0
	root:ProvideLazy("lazy", function(_c)
		callCount += 1
		return 1
	end)
	root:Has("lazy")
	ctx:Expect(callCount):ToBe(0)
end)

suite:Test("Has climbs parent chain", function(ctx)
	local root = Context.Root({ base = true })
	local child = root:Layer({})
	ctx:Expect(child:Has("base")):ToBe(true)
end)

suite:Test("Has returns false for invalid key without throwing", function(ctx)
	local root = Context.Root({})
	ctx:Expect(root:Has("")):ToBe(false)
end)

suite:Test("Has on destroyed context throws", function(ctx)
	local root = Context.Root({})
	root:Destroy()
	ctx:Expect(function()
		root:Has("x")
	end):ToThrow("context is destroyed")
end)

-- ── Set ───────────────────────────────────────────────────────────────────────

suite:Test("Set stores a value retrievable via Require", function(ctx)
	local root = Context.Root({})
	root:Set("key", "value")
	ctx:Expect(root:Require("key")):ToBe("value")
end)

suite:Test("Set stores nil value as present", function(ctx)
	local root = Context.Root({})
	root:Set("k", nil)
	ctx:Expect(root:Has("k")):ToBe(true)
end)

suite:Test("Set clears existing lazy provider for that key", function(ctx)
	local root = Context.Root({})
	root:ProvideLazy("k", function(_c)
		return "lazy"
	end)
	root:Set("k", "direct")
	ctx:Expect(root:Require("k")):ToBe("direct")
end)

suite:Test("Set does not affect parent layer", function(ctx)
	local root = Context.Root({ base = "original" })
	local child = root:Layer({})
	child:Set("base", "shadowed")
	ctx:Expect(root:Require("base")):ToBe("original")
	ctx:Expect(child:Require("base")):ToBe("shadowed")
end)

suite:Test("Set on destroyed context throws", function(ctx)
	local root = Context.Root({})
	root:Destroy()
	ctx:Expect(function()
		root:Set("x", 1)
	end):ToThrow("context is destroyed")
end)

suite:Test("Set on read-only view throws", function(ctx)
	local root = Context.Root({ a = 1 })
	local view = root:View({ "a" })
	ctx:Expect(function()
		view:Set("a", 2)
	end):ToThrow("read-only")
end)

suite:Test("Set with invalid key throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:Set("", 1)
	end):ToThrow("key must be a ContextKey or non-empty string")
end)

-- ── Provide ───────────────────────────────────────────────────────────────────

suite:Test("Provide stores multiple values", function(ctx)
	local root = Context.Root({})
	root:Provide({ a = 1, b = 2 })
	ctx:Expect(root:Require("a")):ToBe(1)
	ctx:Expect(root:Require("b")):ToBe(2)
end)

suite:Test("Provide on destroyed context throws", function(ctx)
	local root = Context.Root({})
	root:Destroy()
	ctx:Expect(function()
		root:Provide({ a = 1 })
	end):ToThrow("context is destroyed")
end)

suite:Test("Provide on read-only view throws", function(ctx)
	local root = Context.Root({ a = 1 })
	local view = root:View({ "a" })
	ctx:Expect(function()
		view:Provide({ a = 2 })
	end):ToThrow("read-only")
end)

suite:Test("Provide with non-table throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:Provide(42 :: any)
	end):ToThrow("values must be a table")
end)

suite:Test("Provide with invalid key throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:Provide({ [""] = 1 })
	end):ToThrow("key must be a ContextKey or non-empty string")
end)

-- ── ProvideLazy ───────────────────────────────────────────────────────────────

suite:Test("ProvideLazy registers a lazy provider", function(ctx)
	local root = Context.Root({})
	root:ProvideLazy("lazy", function(_c)
		return "computed"
	end)
	ctx:Expect(root:Has("lazy")):ToBe(true)
	ctx:Expect(root:Require("lazy")):ToBe("computed")
end)

suite:Test("ProvideLazy passes context to provider", function(ctx)
	local root = Context.Root({ seed = 10 })
	root:ProvideLazy("derived", function(c)
		return (c :: any):Require("seed") * 2
	end)
	ctx:Expect(root:Require("derived")):ToBe(20)
end)

suite:Test("ProvideLazy on destroyed context throws", function(ctx)
	local root = Context.Root({})
	root:Destroy()
	ctx:Expect(function()
		root:ProvideLazy("x", function(_c) return 1 end)
	end):ToThrow("context is destroyed")
end)

suite:Test("ProvideLazy on read-only view throws", function(ctx)
	local root = Context.Root({ a = 1 })
	local view = root:View({ "a" })
	ctx:Expect(function()
		view:ProvideLazy("a", function(_c) return 1 end)
	end):ToThrow("read-only")
end)

suite:Test("ProvideLazy with invalid key throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:ProvideLazy("", function(_c) return 1 end)
	end):ToThrow("key must be a ContextKey or non-empty string")
end)

suite:Test("ProvideLazy with non-function provider throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:ProvideLazy("k", 42 :: any)
	end):ToThrow("provider must be a function")
end)

-- ── Layer ─────────────────────────────────────────────────────────────────────

suite:Test("Layer creates a child context", function(ctx)
	local root = Context.Root({})
	local child = root:Layer({ x = 1 })
	ctx:Expect(Context.IsContext(child)):ToBe(true)
	ctx:Expect(child:Require("x")):ToBe(1)
end)

suite:Test("Layer child reads parent values", function(ctx)
	local root = Context.Root({ base = "parent" })
	local child = root:Layer({})
	ctx:Expect(child:Require("base")):ToBe("parent")
end)

suite:Test("Layer child write does not affect parent", function(ctx)
	local root = Context.Root({ k = "original" })
	local child = root:Layer({})
	child:Set("k", "shadowed")
	ctx:Expect(root:Require("k")):ToBe("original")
end)

suite:Test("Destroying parent destroys child layer", function(ctx)
	local root = Context.Root({})
	local child = root:Layer({})
	root:Destroy()
	ctx:Expect(child:IsDestroyed()):ToBe(true)
end)

suite:Test("Destroying child does not destroy parent", function(ctx)
	local root = Context.Root({})
	local child = root:Layer({})
	child:Destroy()
	ctx:Expect(root:IsDestroyed()):ToBe(false)
end)

suite:Test("Layer cleanup runs on destroy", function(ctx)
	local cleaned = false
	local root = Context.Root({})
	local child = root:Layer({}, function()
		cleaned = true
	end)
	child:Destroy()
	ctx:Expect(cleaned):ToBe(true)
end)

suite:Test("Layer on destroyed context throws", function(ctx)
	local root = Context.Root({})
	root:Destroy()
	ctx:Expect(function()
		root:Layer({})
	end):ToThrow("context is destroyed")
end)

suite:Test("Layer with non-table values throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:Layer(42 :: any)
	end):ToThrow("values must be a table")
end)

suite:Test("Layer with non-function cleanup throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:Layer({}, 42 :: any)
	end):ToThrow("cleanup must be a function or nil")
end)

-- ── View ─────────────────────────────────────────────────────────────────────

suite:Test("View returns a view with selected keys visible", function(ctx)
	local root = Context.Root({ a = 1, b = 2 })
	local view = root:View({ "a" })
	ctx:Expect(view:Require("a")):ToBe(1)
end)

suite:Test("View hides keys not in the selection", function(ctx)
	local root = Context.Root({ a = 1, b = 2 })
	local view = root:View({ "a" })
	ctx:Expect(function()
		view:Require("b")
	end):ToThrow("not visible")
end)

suite:Test("View accepts current API name", function(ctx)
	local root = Context.Root({ x = 5 })
	local view = root:View({ "x" })
	ctx:Expect(view:Require("x")):ToBe(5)
end)

suite:Test("View is read-only: Set throws", function(ctx)
	local root = Context.Root({ a = 1 })
	local view = root:View({ "a" })
	ctx:Expect(function()
		view:Set("a", 99)
	end):ToThrow("read-only")
end)

suite:Test("View is read-only: Provide throws", function(ctx)
	local root = Context.Root({ a = 1 })
	local view = root:View({ "a" })
	ctx:Expect(function()
		view:Provide({ a = 99 })
	end):ToThrow("read-only")
end)

suite:Test("View is read-only: ProvideLazy throws", function(ctx)
	local root = Context.Root({ a = 1 })
	local view = root:View({ "a" })
	ctx:Expect(function()
		view:ProvideLazy("a", function(_c) return 1 end)
	end):ToThrow("read-only")
end)

suite:Test("Destroying source destroys the View", function(ctx)
	local root = Context.Root({ a = 1 })
	local view = root:View({ "a" })
	root:Destroy()
	ctx:Expect(view:IsDestroyed()):ToBe(true)
end)

suite:Test("Destroying View does not destroy source", function(ctx)
	local root = Context.Root({ a = 1 })
	local view = root:View({ "a" })
	view:Destroy()
	ctx:Expect(root:IsDestroyed()):ToBe(false)
end)

suite:Test("View on destroyed context throws", function(ctx)
	local root = Context.Root({ a = 1 })
	root:Destroy()
	ctx:Expect(function()
		root:View({ "a" })
	end):ToThrow("context is destroyed")
end)

suite:Test("View with non-table keys throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:View(42 :: any)
	end):ToThrow("keys must be an array")
end)

suite:Test("View with invalid key in array throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:View({ "" })
	end):ToThrow("key must be a ContextKey or non-empty string")
end)

suite:Test("View supports mixed string and ContextKey selections", function(ctx)
	local key = Context.Key("private")
	local root = Context.Root({ public = 1, [key] = 2, hidden = 3 })
	local view = root:View({ "public", key })
	ctx:Expect(view:Require("public")):ToBe(1)
	ctx:Expect(view:Require(key)):ToBe(2)
	ctx:Expect(view:Maybe("hidden")):ToBe(nil)
end)

suite:Test("View duplicate selections are harmless and still read-only", function(ctx)
	local root = Context.Root({ a = 1 })
	local view = root:View({ "a", "a" })
	ctx:Expect(view:Require("a")):ToBe(1)
	ctx:Expect(function()
		view:Set("a", 2)
	end):ToThrow("read-only")
end)

-- ── Readonly ──────────────────────────────────────────────────────────────────

suite:Test("Readonly returns a view with all keys accessible", function(ctx)
	local root = Context.Root({ x = 10, y = 20 })
	local ro = root:Readonly()
	ctx:Expect(ro:Require("x")):ToBe(10)
	ctx:Expect(ro:Require("y")):ToBe(20)
end)

suite:Test("Readonly view is read-only: Set throws", function(ctx)
	local root = Context.Root({ a = 1 })
	local ro = root:Readonly()
	ctx:Expect(function()
		ro:Set("a", 2)
	end):ToThrow("read-only")
end)

suite:Test("Readonly on a View inherits the key restriction", function(ctx)
	local root = Context.Root({ a = 1, b = 2 })
	local view = root:View({ "a" })
	local ro = view:Readonly()
	ctx:Expect(ro:Require("a")):ToBe(1)
	ctx:Expect(function()
		ro:Require("b")
	end):ToThrow("not visible")
end)

suite:Test("Readonly on destroyed context throws", function(ctx)
	local root = Context.Root({})
	root:Destroy()
	ctx:Expect(function()
		root:Readonly()
	end):ToThrow("context is destroyed")
end)

-- ── Destroy / IsDestroyed ─────────────────────────────────────────────────────

suite:Test("Destroy marks context destroyed", function(ctx)
	local root = Context.Root({})
	ctx:Expect(root:IsDestroyed()):ToBe(false)
	root:Destroy()
	ctx:Expect(root:IsDestroyed()):ToBe(true)
end)

suite:Test("Destroy is idempotent", function(ctx)
	local root = Context.Root({})
	root:Destroy()
	ctx:Expect(function()
		root:Destroy()
	end):ToNotThrow()
end)

suite:Test("Destroy marks destroyed before running callbacks", function(ctx)
	local wasDestroyedDuringCb: boolean? = nil
	local root = Context.Root({})
	root:OnDestroy(function()
		wasDestroyedDuringCb = root:IsDestroyed()
	end)
	root:Destroy()
	ctx:Expect(wasDestroyedDuringCb):ToBe(true)
end)

suite:Test("Destroy recursively destroys children", function(ctx)
	local root = Context.Root({})
	local child = root:Layer({})
	local grandchild = child:Layer({})
	root:Destroy()
	ctx:Expect(child:IsDestroyed()):ToBe(true)
	ctx:Expect(grandchild:IsDestroyed()):ToBe(true)
end)

suite:Test("Destroy resumes callbacks after cleanup errors under Collect policy", function(ctx)
	local errors = ctx:CaptureErrors()
	local order: { string } = {}
	local root = Context.Root({})
	root:Layer({}, function()
		table.insert(order, "cleanup")
		error("cleanup failed")
	end)
	root:OnDestroy(function()
		table.insert(order, "ondestroy")
	end)
	root:Destroy()
	ctx:Expect(order):ToEqual({ "cleanup", "ondestroy" })
	ctx:Expect(errors:HasPhase("Destroy")):ToBe(true)
	errors:Uninstall()
end)

suite:Test("Destroy runs layer cleanup", function(ctx)
	local ran = false
	local root = Context.Root({})
	local child = root:Layer({}, function()
		ran = true
	end)
	child:Destroy()
	ctx:Expect(ran):ToBe(true)
end)

suite:Test("Destroy cleanup error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	local root = Context.Root({})
	local child = root:Layer({}, function()
		error("cleanup boom")
	end)
	child:Destroy()
	ctx:Expect(errors:HasModule("Context")):ToBe(true)
	ctx:Expect(errors:HasPhase("Destroy")):ToBe(true)
	errors:Uninstall()
end)

suite:Test("Destroy OnDestroy callback error routes through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	local root = Context.Root({})
	root:OnDestroy(function()
		error("callback boom")
	end)
	root:Destroy()
	ctx:Expect(errors:HasModule("Context")):ToBe(true)
	ctx:Expect(errors:HasPhase("OnDestroy")):ToBe(true)
	errors:Uninstall()
end)

-- ── OnDestroy ─────────────────────────────────────────────────────────────────

suite:Test("OnDestroy returns a Connection", function(ctx)
	local root = Context.Root({})
	local conn = root:OnDestroy(function() end)
	ctx:Expect(Connection.IsConnection(conn)):ToBe(true)
	ctx:Expect(conn.Connected):ToBe(true)
end)

suite:Test("OnDestroy callback runs when context is destroyed", function(ctx)
	local ran = false
	local root = Context.Root({})
	root:OnDestroy(function()
		ran = true
	end)
	ctx:Expect(ran):ToBe(false)
	root:Destroy()
	ctx:Expect(ran):ToBe(true)
end)

suite:Test("Disconnecting OnDestroy connection prevents callback from running", function(ctx)
	local ran = false
	local root = Context.Root({})
	local conn = root:OnDestroy(function()
		ran = true
	end)
	conn:Disconnect()
	root:Destroy()
	ctx:Expect(ran):ToBe(false)
end)

suite:Test("OnDestroy on already-destroyed context defers callback and returns disconnected connection", function(ctx)
	local ran = false
	local root = Context.Root({})
	root:Destroy()
	local conn = root:OnDestroy(function()
		ran = true
	end)
	ctx:Expect(Connection.IsConnection(conn)):ToBe(true)
	ctx:Expect(conn.Connected):ToBe(false)
	ctx:Expect(ran):ToBe(false)
	ctx.Mock:Flush()
	ctx:Expect(ran):ToBe(true)
end)

suite:Test("OnDestroy with non-function throws", function(ctx)
	local root = Context.Root({})
	ctx:Expect(function()
		root:OnDestroy(42 :: any)
	end):ToThrow("fn must be a function")
end)

return suite:Run()
