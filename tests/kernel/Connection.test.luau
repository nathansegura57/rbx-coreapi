--!strict

local Connection = require(script.Parent.Parent.Parent.src.Connection)
local ErrorHandler = require(script.Parent.Parent.Parent.src.ErrorHandler)
local TestKit = require(script.Parent.Parent.TestKit)

local suite = TestKit.Suite("Connection")

-- ── Construction ──────────────────────────────────────────────────────────────

suite:Test("New() without callback returns connected connection", function(ctx)
	local conn = Connection.New()
	ctx:Expect(Connection.IsConnection(conn)):ToBe(true)
	ctx:Expect(conn.Connected):ToBe(true)
end)

suite:Test("New(fn) stores callback; Connected starts true", function(ctx)
	local called = false
	local conn = Connection.New(function()
		called = true
	end)
	ctx:Expect(conn.Connected):ToBe(true)
	ctx:Expect(called):ToBe(false)
end)

suite:Test("New(nonFunction) throws", function(ctx)
	ctx:Expect(function()
		Connection.New(123 :: any)
	end):ToThrow("disconnectFn must be a function or nil")
end)

-- ── Metatable / handle model ──────────────────────────────────────────────────

suite:Test("getmetatable returns protected string 'Connection'", function(ctx)
	local conn = Connection.New()
	ctx:Expect(getmetatable(conn :: any)):ToBe("Connection")
end)

suite:Test("assigning a field errors with read-only message", function(ctx)
	local conn = Connection.New()
	ctx:Expect(function()
		(conn :: any).Connected = false
	end):ToThrow("is read-only")
end)

-- ── Connected property ────────────────────────────────────────────────────────

suite:Test("Connected reflects live record state after Disconnect", function(ctx)
	local conn = Connection.New()
	ctx:Expect(conn.Connected):ToBe(true)
	conn:Disconnect()
	ctx:Expect(conn.Connected):ToBe(false)
end)

-- ── Disconnect ────────────────────────────────────────────────────────────────

suite:Test("Disconnect calls callback exactly once", function(ctx)
	local callCount = 0
	local conn = Connection.New(function()
		callCount += 1
	end)
	conn:Disconnect()
	conn:Disconnect()
	ctx:Expect(callCount):ToBe(1)
end)

suite:Test("Disconnect sets Connected = false before calling callback", function(ctx)
	local connectedDuringCallback: boolean? = nil
	local conn: Connection.Connection
	conn = Connection.New(function()
		connectedDuringCallback = conn.Connected
	end)
	conn:Disconnect()
	ctx:Expect(connectedDuringCallback):ToBe(false)
end)

suite:Test("Disconnect with no callback is a no-op", function(ctx)
	local conn = Connection.New()
	ctx:Expect(function()
		conn:Disconnect()
	end):ToNotThrow()
	ctx:Expect(conn.Connected):ToBe(false)
end)

suite:Test("Disconnect on already-disconnected is idempotent", function(ctx)
	local conn = Connection.New()
	conn:Disconnect()
	ctx:Expect(function()
		conn:Disconnect()
	end):ToNotThrow()
end)

suite:Test("Disconnect routes callback errors through ErrorHandler", function(ctx)
	local errors = ctx:CaptureErrors()
	local conn = Connection.New(function()
		error("boom")
	end)
	conn:Disconnect()
	ctx:Expect(errors:HasModule("Connection")):ToBe(true)
	ctx:Expect(errors:HasPhase("Disconnect")):ToBe(true)
	errors:Uninstall()
end)

suite:Test("Disconnect clears callback so ErrorHandler throw does not re-run it", function(ctx)
	local callCount = 0
	ErrorHandler.SetPolicy("Throw")
	local conn = Connection.New(function()
		callCount += 1
		error("fail")
	end)
	-- Throw policy means Disconnect itself may propagate; wrap in pcall.
	pcall(function()
		conn:Disconnect()
	end)
	-- Even if it threw, callback must not have run again.
	ctx:Expect(callCount):ToBe(1)
	-- Connection must remain disconnected.
	ctx:Expect(conn.Connected):ToBe(false)
end)

suite:Test("Disconnect on invalid handle throws", function(ctx)
	ctx:Expect(function()
		Connection.Disconnect({} :: any)
	end):ToThrow("invalid connection")
end)

suite:Test("Disconnect callback can re-enter Disconnect without running twice", function(ctx)
	local callCount = 0
	local conn: Connection.Connection
	conn = Connection.New(function()
		callCount += 1
		conn:Disconnect()
	end)
	conn:Disconnect()
	ctx:Expect(callCount):ToBe(1)
	ctx:Expect(conn.Connected):ToBe(false)
end)

suite:Test("Unknown fields read as nil and do not masquerade as methods", function(ctx)
	local conn = Connection.New()
	ctx:Expect((conn :: any).MadeUpField):ToBe(nil)
end)

-- ── IsConnection ──────────────────────────────────────────────────────────────

suite:Test("IsConnection returns true for live connection", function(ctx)
	local conn = Connection.New()
	ctx:Expect(Connection.IsConnection(conn)):ToBe(true)
end)

suite:Test("IsConnection returns true for disconnected connection (identity survives)", function(ctx)
	local conn = Connection.New()
	conn:Disconnect()
	ctx:Expect(Connection.IsConnection(conn)):ToBe(true)
end)

suite:Test("IsConnection returns false for nil", function(ctx)
	ctx:Expect(Connection.IsConnection(nil)):ToBe(false)
end)

suite:Test("IsConnection returns false for plain table", function(ctx)
	ctx:Expect(Connection.IsConnection({})):ToBe(false)
end)

suite:Test("IsConnection returns false for non-table", function(ctx)
	ctx:Expect(Connection.IsConnection(42)):ToBe(false)
end)

return suite:Run()
