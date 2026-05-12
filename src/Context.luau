--!strict

local Connection = require(script.Parent.Connection)
local ErrorHandler = require(script.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Scheduler)

local Context = {}

-- Base Context
export type BaseContext<T> = {
	Require: <V>(self: BaseContext<T>, key: ContextKey<V> | string) -> V,
	Maybe: <V>(self: BaseContext<T>, key: ContextKey<V> | string) -> V?,
	Has: (self: BaseContext<T>, key: ContextKey<unknown> | string) -> boolean,
	Set: <V>(self: BaseContext<T>, key: ContextKey<V> | string, value: V) -> (),
	Provide: (self: BaseContext<T>, values: { [ContextKey<unknown> | string]: unknown }) -> (),
	Readonly: (self: BaseContext<T>) -> BaseContext<T>,
	Destroy: (self: BaseContext<T>) -> (),
	IsDestroyed: (self: BaseContext<T>) -> boolean,
	OnDestroy: (self: BaseContext<T>, fn: () -> ()) -> Connection.Connection,
}

-- Public types

export type ContextKey<T> = {}

export type Context<T> = BaseContext<T> & {
	ProvideLazy: <V>(self: Context<T>, key: ContextKey<V> | string, provider: (BaseContext<unknown>) -> V) -> (),
	Layer: <L>(self: Context<T>, values: L, cleanup: (() -> ())?) -> BaseContext<L>,
	View: (self: Context<T>, keys: { ContextKey<unknown> | string }) -> BaseContext<unknown>,
}

-- Internal record types

type StorageEntry = {
	Value: any,
}

type LazyEntry = {
	Provider: (ctx: any) -> any,
	Resolving: boolean,
}

type OnDestroyEntry = {
	Fn: () -> (),
}

type ContextRecord = {
	Kind: "root" | "layer" | "view",
	Parent: any?,
	Source: any?,
	VisibleKeys: { [any]: true }?,
	Mutable: boolean,
	Destroyed: boolean,
	Storage: { [any]: StorageEntry },
	Lazy: { [any]: LazyEntry },
	Children: { any },
	Cleanup: (() -> ())?,
	OnDestroyCallbacks: { OnDestroyEntry },
}

type KeyRecord = {
	Name: string,
}

-- Private state (weak keys so handles can be GC'd)

local contextRecords: { [any]: ContextRecord } = setmetatable({}, { __mode = "k" }) :: any
local keyRecords: { [any]: KeyRecord } = setmetatable({}, { __mode = "k" }) :: any

-- Key helpers

local function isValidKey(key: any): boolean
	if type(key) == "string" then
		return #(key :: string) > 0
	end
	return keyRecords[key] ~= nil
end

local function keyDisplayName(key: any): string
	if type(key) == "string" then
		return key :: string
	end
	local kr: KeyRecord? = keyRecords[key]
	return if kr ~= nil then kr.Name else "<unknown>"
end

-- Recursive key lookup (resolves lazy providers)
-- callerHandle is the context passed to lazy providers (the one on which Require was called).

local function findKey(callerHandle: any, handle: any, key: any): (boolean, any)
	local record: ContextRecord? = contextRecords[handle]
	if record == nil or record.Destroyed then
		return false, nil
	end

	if record.Kind == "view" then
		local visKeys = record.VisibleKeys
		if visKeys ~= nil and not visKeys[key] then
			return false, nil
		end
		if record.Source ~= nil then
			return findKey(callerHandle, record.Source, key)
		end
		return false, nil
	end

	local entry: StorageEntry? = record.Storage[key]
	if entry ~= nil then
		return true, entry.Value
	end

	local lazy: LazyEntry? = record.Lazy[key]
	if lazy ~= nil then
		if lazy.Resolving then
			error(`Context.Require: lazy provider cycle for key '{keyDisplayName(key)}'`)
		end
		lazy.Resolving = true
		local ok, result = ErrorHandler.Protect(function() return lazy.Provider(callerHandle) end, "Context", "LazyProvider", keyDisplayName(key))
		lazy.Resolving = false
		if not ok then
			-- Reached only when policy is not Throw; Report did not propagate.
			error(`Context.Require: lazy provider failed for key '{keyDisplayName(key)}'`)
		end
		record.Storage[key] = { Value = result }
		record.Lazy[key] = nil :: any
		return true, result
	end

	if record.Parent ~= nil then
		return findKey(callerHandle, record.Parent, key)
	end

	return false, nil
end

-- Recursive presence check (does NOT resolve lazy providers)

local function hasKeyInChain(handle: any, key: any): boolean
	local record: ContextRecord? = contextRecords[handle]
	if record == nil or record.Destroyed then
		return false
	end

	if record.Kind == "view" then
		local visKeys = record.VisibleKeys
		if visKeys ~= nil and not visKeys[key] then
			return false
		end
		if record.Source ~= nil then
			return hasKeyInChain(record.Source, key)
		end
		return false
	end

	if record.Storage[key] ~= nil then
		return true
	end
	if record.Lazy[key] ~= nil then
		return true
	end
	if record.Parent ~= nil then
		return hasKeyInChain(record.Parent, key)
	end
	return false
end

-- Recursive destruction

local function destroyHandle(handle: any): ()
	local record: ContextRecord? = contextRecords[handle]
	if record == nil or record.Destroyed then
		return
	end
	-- Mark destroyed first so it is observable even if a callback errors and throws.
	record.Destroyed = true

	-- Destroy children (layers and views registered under this context/view).
	local childrenCopy = table.clone(record.Children)
	table.clear(record.Children)
	for _, child in childrenCopy do
		destroyHandle(child)
	end

	if record.Kind ~= "view" then
		-- Run cleanup for roots and layers.
		local cleanup = record.Cleanup
		record.Cleanup = nil
		if cleanup ~= nil then
			ErrorHandler.Protect(cleanup, "Context", "Destroy")
		end
	end

	-- Run OnDestroy callbacks.
	local callbacksCopy = table.clone(record.OnDestroyCallbacks)
	table.clear(record.OnDestroyCallbacks)
	for _, entry in callbacksCopy do
		ErrorHandler.Protect(entry.Fn, "Context", "OnDestroy")
	end

	-- Release storage for non-views (views have no storage).
	if record.Kind ~= "view" then
		table.clear(record.Storage)
		table.clear(record.Lazy)
	end
end

-- Handle construction

local contextMethods: { [string]: any } = {}

local contextMeta: { [string]: any } = {
	__index = contextMethods,
	__newindex = function(_: any, key: string, _: any): ()
		error(`Context: '{tostring(key)}' is read-only`)
	end,
	__metatable = "Context",
}

local function newHandle(record: ContextRecord): any
	local handle: any = setmetatable({}, contextMeta)
	contextRecords[handle] = record
	return handle
end

local function newRecord(kind: "root" | "layer" | "view"): ContextRecord
	return {
		Kind = kind,
		Parent = nil,
		Source = nil,
		VisibleKeys = nil,
		Mutable = true,
		Destroyed = false,
		Storage = {},
		Lazy = {},
		Children = {},
		Cleanup = nil,
		OnDestroyCallbacks = {},
	}
end

-- Methods

contextMethods.Require = function(self: any, key: any): any
	local record: ContextRecord? = contextRecords[self]
	if record == nil or record.Destroyed then
		error("Context.Require: context is destroyed")
	end
	if record.Kind == "view" and record.Source ~= nil then
		local sr: ContextRecord? = contextRecords[record.Source]
		if sr == nil or sr.Destroyed then
			error("Context.Require: source context is destroyed")
		end
	end
	if not isValidKey(key) then
		error("Context.Require: key must be a ContextKey or non-empty string")
	end
	if record.Kind == "view" then
		local visKeys = record.VisibleKeys
		if visKeys ~= nil and not visKeys[key] then
			error(`Context.Require: key '{keyDisplayName(key)}' is not visible in this view`)
		end
		local source = record.Source
		if source ~= nil then
			local found, value = findKey(self, source, key)
			if not found then
				error(`Context.Require: missing key '{keyDisplayName(key)}'`)
			end
			return value
		end
		error(`Context.Require: missing key '{keyDisplayName(key)}'`)
	end
	local found, value = findKey(self, self, key)
	if not found then
		error(`Context.Require: missing key '{keyDisplayName(key)}'`)
	end
	return value
end

contextMethods.Maybe = function(self: any, key: any): any
	local record: ContextRecord? = contextRecords[self]
	if record == nil or record.Destroyed then
		error("Context.Maybe: context is destroyed")
	end
	if record.Kind == "view" and record.Source ~= nil then
		local sr: ContextRecord? = contextRecords[record.Source]
		if sr == nil or sr.Destroyed then
			error("Context.Maybe: source context is destroyed")
		end
	end
	if not isValidKey(key) then
		return nil
	end
	if record.Kind == "view" then
		local visKeys = record.VisibleKeys
		if visKeys ~= nil and not visKeys[key] then
			return nil
		end
		local source = record.Source
		if source ~= nil then
			local found, value = findKey(self, source, key)
			return if found then value else nil
		end
		return nil
	end
	local found, value = findKey(self, self, key)
	return if found then value else nil
end

contextMethods.Has = function(self: any, key: any): boolean
	local record: ContextRecord? = contextRecords[self]
	if record == nil or record.Destroyed then
		error("Context.Has: context is destroyed")
	end
	if record.Kind == "view" and record.Source ~= nil then
		local sr: ContextRecord? = contextRecords[record.Source]
		if sr == nil or sr.Destroyed then
			error("Context.Has: source context is destroyed")
		end
	end
	if not isValidKey(key) then
		return false
	end
	return hasKeyInChain(self, key)
end

contextMethods.Set = function(self: any, key: any, value: any): ()
	local record: ContextRecord? = contextRecords[self]
	if record == nil or record.Destroyed then
		error("Context.Set: context is destroyed")
	end
	if not record.Mutable then
		error("Context.Set: context is read-only")
	end
	if not isValidKey(key) then
		error("Context.Set: key must be a ContextKey or non-empty string")
	end
	record.Storage[key] = { Value = value }
	record.Lazy[key] = nil :: any
end

contextMethods.Provide = function(self: any, values: any): ()
	local record: ContextRecord? = contextRecords[self]
	if record == nil or record.Destroyed then
		error("Context.Provide: context is destroyed")
	end
	if not record.Mutable then
		error("Context.Provide: context is read-only")
	end
	if type(values) ~= "table" then
		error("Context.Provide: values must be a table")
	end
	-- Validate all keys first.
	for k in values :: { [any]: any } do
		if not isValidKey(k) then
			error("Context.Provide: key must be a ContextKey or non-empty string")
		end
	end
	-- Apply all values.
	for k, v in values :: { [any]: any } do
		record.Storage[k] = { Value = v }
		record.Lazy[k] = nil :: any
	end
end

contextMethods.ProvideLazy = function(self: any, key: any, provider: any): ()
	local record: ContextRecord? = contextRecords[self]
	if record == nil or record.Destroyed then
		error("Context.ProvideLazy: context is destroyed")
	end
	if not record.Mutable then
		error("Context.ProvideLazy: context is read-only")
	end
	if not isValidKey(key) then
		error("Context.ProvideLazy: key must be a ContextKey or non-empty string")
	end
	if type(provider) ~= "function" then
		error("Context.ProvideLazy: provider must be a function")
	end
	record.Lazy[key] = { Provider = provider, Resolving = false }
end

contextMethods.Layer = function(self: any, values: any, cleanup: any): any
	local record: ContextRecord? = contextRecords[self]
	if record == nil or record.Destroyed then
		error("Context.Layer: context is destroyed")
	end
	if type(values) ~= "table" then
		error("Context.Layer: values must be a table")
	end
	if cleanup ~= nil and type(cleanup) ~= "function" then
		error("Context.Layer: cleanup must be a function or nil")
	end
	local child = newRecord("layer")
	child.Parent = self
	child.Cleanup = cleanup
	-- Shallow-copy values into child storage.
	for k, v in values :: { [any]: any } do
		child.Storage[k] = { Value = v }
	end
	local childHandle = newHandle(child)
	table.insert(record.Children, childHandle)
	return childHandle
end

contextMethods.View = function(self: any, keys: any): any
	local record: ContextRecord? = contextRecords[self]
	if record == nil or record.Destroyed then
		error("Context.View: context is destroyed")
	end
	if type(keys) ~= "table" then
		error("Context.View: keys must be an array")
	end
	local visibleKeys: { [any]: true } = {}
	for _, k in ipairs(keys) do
		if not isValidKey(k) then
			error("Context.View: key must be a ContextKey or non-empty string")
		end
		visibleKeys[k] = true
	end
	local view = newRecord("view")
	view.Source = self
	view.VisibleKeys = visibleKeys
	view.Mutable = false
	local viewHandle = newHandle(view)
	table.insert(record.Children, viewHandle)
	return viewHandle
end

contextMethods.Readonly = function(self: any): any
	local record: ContextRecord? = contextRecords[self]
	if record == nil or record.Destroyed then
		error("Context.Readonly: context is destroyed")
	end
	local view = newRecord("view")
	view.Kind = "view"
	view.Source = self
	view.Mutable = false
	-- Inherit the visible-key restriction from a view source; nil means all keys.
	if record.Kind == "view" then
		view.VisibleKeys = record.VisibleKeys
	else
		view.VisibleKeys = nil
	end
	local viewHandle = newHandle(view)
	table.insert(record.Children, viewHandle)
	return viewHandle
end

contextMethods.Destroy = function(self: any): ()
	destroyHandle(self)
end

contextMethods.IsDestroyed = function(self: any): boolean
	local record: ContextRecord? = contextRecords[self]
	return record == nil or record.Destroyed
end

contextMethods.OnDestroy = function(self: any, fn: any): Connection.Connection
	if type(fn) ~= "function" then
		error("Context.OnDestroy: fn must be a function")
	end
	local record: ContextRecord? = contextRecords[self]
	if record == nil or record.Destroyed then
		Scheduler.Defer(fn :: () -> ())
		local conn = Connection.New(nil)
		conn:Disconnect()
		return conn
	end
	local entry: OnDestroyEntry = { Fn = fn }
	local callbacks = record.OnDestroyCallbacks
	table.insert(callbacks, entry)
	return Connection.New(function()
		for i, cb in callbacks do
			if cb == entry then
				table.remove(callbacks, i)
				break
			end
		end
	end)
end

-- Key metatable

local keyMeta: { [string]: any } = {
	__newindex = function(_: any, key: string, _: any): ()
		error(`ContextKey: '{tostring(key)}' is read-only`)
	end,
	__metatable = "ContextKey",
}

-- Public API

function Context.Root(values: { [any]: any }): Context<any>
	if type(values) ~= "table" then
		error("Context.Root: values must be a table")
	end
	local record = newRecord("root")
	for k, v in values do
		record.Storage[k] = { Value = v }
	end
	return newHandle(record)
end

function Context.Key<T>(name: string): ContextKey<T>
	if type(name) ~= "string" or #name == 0 then
		error("Context.Key: name must be a non-empty string")
	end
	local handle: any = setmetatable({}, keyMeta)
	keyRecords[handle] = { Name = name }
	return handle
end

function Context.IsContext(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	return contextRecords[value :: any] ~= nil
end

return Context

