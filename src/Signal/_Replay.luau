--!strict

local Scheduler = require(script.Parent.Parent.Scheduler)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)

local Records = require(script.Parent._Records)
local Validation = require(script.Parent._Validation)
local Types = require(script.Parent._Types)

local Replay = {}

type ListenerEntry = Types.ListenerEntry
type ReplayEntry = Types.ReplayEntry
type SignalRecord = Types.SignalRecord
type SignalMethods = Types.SignalMethods


function Replay.removeExpiredTimeReplayEntries(signalRecord: SignalRecord): ()
	local currentTime = Scheduler.Now()
	local replayWindow = signalRecord.ReplayTimeWindow
	local replayBuffer = signalRecord.ReplayBuffer

	local replayIndex = 1

	while replayIndex <= #replayBuffer do
		if currentTime - replayBuffer[replayIndex].Timestamp > replayWindow then
			table.remove(replayBuffer, replayIndex)
		else
			replayIndex += 1
		end
	end
end

function Replay.storePayloadForActiveReplayPolicy(signalRecord: SignalRecord, payload: any): ()
	local replayPolicy = signalRecord.ReplayPolicy

	if replayPolicy == nil then
		return
	end

	local replayEntry: ReplayEntry = {
		Value = payload,
		Timestamp = Scheduler.Now(),
	}

	table.insert(signalRecord.ReplayBuffer, replayEntry)

	if replayPolicy == "Count" then
		while #signalRecord.ReplayBuffer > signalRecord.ReplayCountLimit do
			table.remove(signalRecord.ReplayBuffer, 1)
		end
	else
		Replay.removeExpiredTimeReplayEntries(signalRecord)
	end
end

function Replay.scheduleReplayForNewListener(signalRecord: SignalRecord, listenerEntry: ListenerEntry): ()
	if signalRecord.ReplayPolicy == nil then
		return
	end

	if signalRecord.ReplayPolicy == "Time" then
		Replay.removeExpiredTimeReplayEntries(signalRecord)
	end

	for _, replayEntry in signalRecord.ReplayBuffer do
		local replayedPayload = replayEntry.Value

		Scheduler.Defer(function()
			if listenerEntry.Connected then
				ErrorHandler.Protect(function()
					listenerEntry.Fn(replayedPayload)
				end, "Signal", "Replay")
			end
		end)
	end
end


function Replay.defineReplayPolicyMethods(signalMethods: SignalMethods): ()
	function signalMethods:ReplayCount(count: number): any
		local replayCount = Validation.ensurePositiveInteger(count, "Signal.ReplayCount: count must be a positive integer")
		local signalRecord = Records.getLiveSignalRecordOrError(self, "Signal.ReplayCount: signal is destroyed")

		if signalRecord.ReplayPolicy ~= nil then
			ErrorHandler.RaiseUsageError("Signal: only one replay policy may be applied")
		end

		signalRecord.ReplayPolicy = "Count"
		signalRecord.ReplayCountLimit = replayCount

		return self
	end

	function signalMethods:ReplayTime(seconds: number): any
		local replaySeconds = Validation.ensurePositiveSeconds(seconds, "Signal.ReplayTime: seconds must be positive")
		local signalRecord = Records.getLiveSignalRecordOrError(self, "Signal.ReplayTime: signal is destroyed")

		if signalRecord.ReplayPolicy ~= nil then
			ErrorHandler.RaiseUsageError("Signal: only one replay policy may be applied")
		end

		signalRecord.ReplayPolicy = "Time"
		signalRecord.ReplayTimeWindow = replaySeconds

		return self
	end

	function signalMethods:ClearReplay(): any
		local signalRecord = Records.getSignalRecord(self)

		if signalRecord == nil or signalRecord.Destroyed then
			return self
		end

		signalRecord.ReplayPolicy = nil
		signalRecord.ReplayCountLimit = 0
		signalRecord.ReplayTimeWindow = 0

		table.clear(signalRecord.ReplayBuffer)

		return self
	end
end


return table.freeze(Replay)

