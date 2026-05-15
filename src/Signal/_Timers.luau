--!strict

local Scheduler = require(script.Parent.Parent.Scheduler)

local Records = require(script.Parent._Records)
local Validation = require(script.Parent._Validation)
local Types = require(script.Parent._Types)

local Timers = {}

type SignalModule = Types.SignalModule


function Timers.createSignalThatFiresOnceAfterDelay(Signal: SignalModule, seconds: number): any
	local delaySeconds = Validation.ensureNonNegativeSeconds(seconds, "Signal.After: seconds must be non-negative")

	local signal = Signal.New()
	local timerHandle = Scheduler.Delay(delaySeconds, function()
		local signalRecord = Records.getSignalRecord(signal)

		if signalRecord == nil or signalRecord.Destroyed then
			return
		end

		signal:Fire(nil)
		signal:Destroy()
	end)

	Records.attachTimerHandle(signal, timerHandle)

	return signal
end

function Timers.createSignalThatFiresEveryInterval(Signal: SignalModule, seconds: number): any
	local intervalSeconds = Validation.ensurePositiveSeconds(seconds, "Signal.Every: seconds must be positive")

	local signal = Signal.New()
	local signalRecord = Records.getSignalRecord(signal)

	local function scheduleNextTick(): ()
		local timerHandle = Scheduler.Delay(intervalSeconds, function()
			local currentRecord = Records.getSignalRecord(signal)

			if currentRecord == nil or currentRecord.Destroyed then
				return
			end

			signal:Fire(nil)

			if not currentRecord.Destroyed then
				table.clear(currentRecord.TimerHandles)
				scheduleNextTick()
			end
		end)

		if signalRecord ~= nil then
			table.clear(signalRecord.TimerHandles)
			table.insert(signalRecord.TimerHandles, timerHandle)
		end
	end

	scheduleNextTick()

	return signal
end


return table.freeze(Timers)

