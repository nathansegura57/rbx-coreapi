--!strict

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)

local Records = require(script.Parent._Records)
local Types = require(script.Parent._Types)

local RobloxBridge = {}

type SignalModule = Types.SignalModule


function RobloxBridge.createSignalFromRobloxSignal(Signal: SignalModule, rbxSignal: RBXScriptSignal, mapper: ((...any) -> any)?): any
	if typeof(rbxSignal) ~= "RBXScriptSignal" then
		error("Signal.FromRoblox: expected RBXScriptSignal", 2)
	end

	if mapper ~= nil and type(mapper) ~= "function" then
		error("Signal.FromRoblox: mapper must be a function or nil", 2)
	end

	local signal = Signal.New()

	local robloxConnection = (rbxSignal :: any):Connect(function(...)
		local signalRecord = Records.getSignalRecord(signal)

		if signalRecord == nil or signalRecord.Destroyed then
			return
		end

		local payload: any = table.pack(...)

		if mapper ~= nil then
			local mapperSucceeded, mappedPayload = ErrorHandler.Protect(function()
				return mapper(table.unpack(payload, 1, payload.n))
			end, "Signal", "FromRoblox")

			if not mapperSucceeded then
				return
			end

			payload = mappedPayload
		end

		signal:Fire(payload)
	end)

	Records.attachCleanupCallback(signal, function()
		robloxConnection:Disconnect()
	end)

	return signal
end


return table.freeze(RobloxBridge)

