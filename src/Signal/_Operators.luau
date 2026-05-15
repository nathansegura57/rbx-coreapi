--!strict

local Scheduler = require(script.Parent.Parent.Scheduler)
local ErrorHandler = require(script.Parent.Parent.ErrorHandler)

local Records = require(script.Parent._Records)
local Validation = require(script.Parent._Validation)
local Types = require(script.Parent._Types)

local Operators = {}

type ListenerEntry = Types.ListenerEntry
type SignalRecord = Types.SignalRecord
type SignalMethods = Types.SignalMethods
type SignalModule = Types.SignalModule


function Operators.createPackedArrayFromPresenceAwareBuffer(buffer: { { Value: any } }, count: number): { any }
	local packedArray = table.create(count)

	for index = 1, count do
		packedArray[index] = buffer[index].Value
	end

	(packedArray :: any).n = count

	return packedArray
end

function Operators.validateLiveSignalArgument(Signal: SignalModule, signalValue: any, usageErrorMessage: string): ()
	if not Signal.IsSignal(signalValue) then
		error(usageErrorMessage, 3)
	end

	local signalRecord = Records.getSignalRecord(signalValue)

	if signalRecord == nil or signalRecord.Destroyed then
		error(usageErrorMessage, 3)
	end
end

function Operators.getThrottleOptions(options: any): (boolean, boolean)
	local leading = true
	local trailing = true

	if options == nil then
		return leading, trailing
	end

	if type(options) ~= "table" then
		error("Signal.Throttle: opts must be a table or nil", 3)
	end

	if options.Leading ~= nil then
		if type(options.Leading) ~= "boolean" then
			error("Signal.Throttle: Leading must be a boolean or nil", 3)
		end

		leading = options.Leading
	end

	if options.Trailing ~= nil then
		if type(options.Trailing) ~= "boolean" then
			error("Signal.Throttle: Trailing must be a boolean or nil", 3)
		end

		trailing = options.Trailing
	end

	return leading, trailing
end


function Operators.defineReactiveOperatorMethods(Signal: SignalModule, signalMethods: SignalMethods): ()
	function signalMethods:Map(mapper: (any) -> any): any
		Validation.ensureCallback(mapper, "Signal.Map: mapper must be a function")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			local mapperSucceeded, mappedPayload = ErrorHandler.Protect(function()
				return mapper(payload)
			end, "Signal", "Map")

			if mapperSucceeded then
				derivedSignal:Fire(mappedPayload)
			end
		end)

		return derivedSignal
	end

	function signalMethods:Filter(predicate: (any) -> boolean): any
		Validation.ensureCallback(predicate, "Signal.Filter: predicate must be a function")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			local predicateSucceeded, shouldForward = ErrorHandler.Protect(function()
				return predicate(payload)
			end, "Signal", "Filter")

			if predicateSucceeded and shouldForward == true then
				derivedSignal:Fire(payload)
			end
		end)

		return derivedSignal
	end

	function signalMethods:Scan(reducer: (any, any) -> any, seed: any): any
		Validation.ensureCallback(reducer, "Signal.Scan: reducer must be a function")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local accumulator = seed

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			local reducerSucceeded, nextAccumulator = ErrorHandler.Protect(function()
				return reducer(accumulator, payload)
			end, "Signal", "Scan")

			if reducerSucceeded then
				accumulator = nextAccumulator
				derivedSignal:Fire(accumulator)
			end
		end)

		return derivedSignal
	end

	function signalMethods:MergeMap(selector: (any) -> any): any
		Validation.ensureCallback(selector, "Signal.MergeMap: selector must be a function")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local innerListenerEntries: { ListenerEntry } = {}

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			local selectorSucceeded, innerSignal = ErrorHandler.Protect(function()
				return selector(payload)
			end, "Signal", "MergeMap")

			if not selectorSucceeded then
				return
			end

			Operators.validateLiveSignalArgument(Signal, innerSignal, "Signal.MergeMap: selector must return a Signal")

			local innerRecord = Records.getSignalRecord(innerSignal) :: SignalRecord

			local innerListenerEntry: ListenerEntry = {
				Connected = true,

				Fn = function(innerPayload: any): ()
					if not derivedRecord.Destroyed then
						derivedSignal:Fire(innerPayload)
					end
				end,
			}

			table.insert(innerRecord.Listeners, innerListenerEntry)
			table.insert(innerListenerEntries, innerListenerEntry)

			table.insert(innerRecord.CleanupCallbacks, function()
				innerListenerEntry.Connected = false
			end)
		end)

		Records.attachCleanupCallback(derivedSignal, function()
			for _, innerListenerEntry in innerListenerEntries do
				innerListenerEntry.Connected = false
			end

			table.clear(innerListenerEntries)
		end)

		return derivedSignal
	end

	function signalMethods:SwitchMap(selector: (any) -> any): any
		Validation.ensureCallback(selector, "Signal.SwitchMap: selector must be a function")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local currentInnerListenerEntry: ListenerEntry? = nil

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			local selectorSucceeded, innerSignal = ErrorHandler.Protect(function()
				return selector(payload)
			end, "Signal", "SwitchMap")

			if not selectorSucceeded then
				return
			end

			Operators.validateLiveSignalArgument(Signal, innerSignal, "Signal.SwitchMap: selector must return a Signal")

			if currentInnerListenerEntry ~= nil then
				currentInnerListenerEntry.Connected = false
			end

			local innerRecord = Records.getSignalRecord(innerSignal) :: SignalRecord

			local innerListenerEntry: ListenerEntry = {
				Connected = true,

				Fn = function(innerPayload: any): ()
					if not derivedRecord.Destroyed then
						derivedSignal:Fire(innerPayload)
					end
				end,
			}

			currentInnerListenerEntry = innerListenerEntry

			table.insert(innerRecord.Listeners, innerListenerEntry)

			table.insert(innerRecord.CleanupCallbacks, function()
				if currentInnerListenerEntry == innerListenerEntry then
					currentInnerListenerEntry = nil
				end

				innerListenerEntry.Connected = false
			end)
		end)

		Records.attachCleanupCallback(derivedSignal, function()
			if currentInnerListenerEntry ~= nil then
				currentInnerListenerEntry.Connected = false
				currentInnerListenerEntry = nil
			end
		end)

		return derivedSignal
	end

	function signalMethods:Take(count: number): any
		local eventLimit = Validation.ensurePositiveInteger(count, "Signal.Take: count must be a positive integer")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local seenEventCount = 0

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			seenEventCount += 1
			derivedSignal:Fire(payload)

			if seenEventCount >= eventLimit then
				derivedSignal:Destroy()
			end
		end)

		return derivedSignal
	end

	function signalMethods:Skip(count: number): any
		local eventsToSkip = Validation.ensureNonNegativeInteger(count, "Signal.Skip: count must be a non-negative integer")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local skippedEventCount = 0

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			if skippedEventCount < eventsToSkip then
				skippedEventCount += 1
				return
			end

			derivedSignal:Fire(payload)
		end)

		return derivedSignal
	end

	function signalMethods:TakeWhile(predicate: (any) -> boolean): any
		Validation.ensureCallback(predicate, "Signal.TakeWhile: predicate must be a function")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			local predicateSucceeded, shouldContinue = ErrorHandler.Protect(function()
				return predicate(payload)
			end, "Signal", "TakeWhile")

			if not predicateSucceeded or shouldContinue ~= true then
				derivedSignal:Destroy()
				return
			end

			derivedSignal:Fire(payload)
		end)

		return derivedSignal
	end

	function signalMethods:SkipWhile(predicate: (any) -> boolean): any
		Validation.ensureCallback(predicate, "Signal.SkipWhile: predicate must be a function")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local isStillSkipping = true

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			if not isStillSkipping then
				derivedSignal:Fire(payload)
				return
			end

			local predicateSucceeded, shouldContinueSkipping = ErrorHandler.Protect(function()
				return predicate(payload)
			end, "Signal", "SkipWhile")

			if not predicateSucceeded or shouldContinueSkipping ~= true then
				isStillSkipping = false
				derivedSignal:Fire(payload)
			end
		end)

		return derivedSignal
	end

	function signalMethods:TakeUntil(stopper: any): any
		Operators.validateLiveSignalArgument(Signal, stopper, "Signal.TakeUntil: stopper must be a live Signal")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local stopperRecord = Records.getSignalRecord(stopper) :: SignalRecord

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if not derivedRecord.Destroyed then
				derivedSignal:Fire(payload)
			end
		end)

		local stopperListenerEntry: ListenerEntry = {
			Connected = true,

			Fn = function(_payload: any): ()
				if not derivedRecord.Destroyed then
					derivedSignal:Destroy()
				end
			end,
		}

		table.insert(stopperRecord.Listeners, stopperListenerEntry)

		table.insert(stopperRecord.CleanupCallbacks, function()
			if not derivedRecord.Destroyed then
				derivedSignal:Destroy()
			end
		end)

		Records.attachCleanupCallback(derivedSignal, function()
			stopperListenerEntry.Connected = false
			Records.compactDisconnectedListenersWhenSafe(stopperRecord)
		end)

		return derivedSignal
	end

	function signalMethods:SkipUntil(starter: any): any
		Operators.validateLiveSignalArgument(Signal, starter, "Signal.SkipUntil: starter must be a live Signal")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local starterRecord = Records.getSignalRecord(starter) :: SignalRecord
		local hasStartedForwarding = false

		local starterListenerEntry: ListenerEntry

		starterListenerEntry = {
			Connected = true,

			Fn = function(_payload: any): ()
				if not hasStartedForwarding then
					hasStartedForwarding = true
					starterListenerEntry.Connected = false
				end
			end,
		}

		table.insert(starterRecord.Listeners, starterListenerEntry)

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if not derivedRecord.Destroyed and hasStartedForwarding then
				derivedSignal:Fire(payload)
			end
		end)

		Records.attachCleanupCallback(derivedSignal, function()
			starterListenerEntry.Connected = false
		end)

		return derivedSignal
	end

	function signalMethods:Debounce(seconds: number): any
		local debounceSeconds = Validation.ensureNonNegativeSeconds(seconds, "Signal.Debounce: seconds must be non-negative")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local pendingHandle: any = nil
		local pendingPayload: any = nil
		local hasPendingPayload = false

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			if pendingHandle ~= nil then
				Scheduler.Cancel(pendingHandle)
			end

			hasPendingPayload = true
			pendingPayload = payload

			pendingHandle = Scheduler.Delay(debounceSeconds, function()
				pendingHandle = nil

				if not derivedRecord.Destroyed and hasPendingPayload then
					local payloadToFire = pendingPayload

					hasPendingPayload = false
					pendingPayload = nil

					derivedSignal:Fire(payloadToFire)
				end
			end)
		end)

		Records.attachCleanupCallback(derivedSignal, function()
			if pendingHandle ~= nil then
				Scheduler.Cancel(pendingHandle)
				pendingHandle = nil
			end
		end)

		return derivedSignal
	end

	function signalMethods:Throttle(seconds: number, options: any): any
		local throttleSeconds = Validation.ensurePositiveSeconds(seconds, "Signal.Throttle: seconds must be positive")
		local leading, trailing = Operators.getThrottleOptions(options)

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord

		local isWindowOpen = false
		local hasPendingTrailingPayload = false
		local pendingTrailingPayload: any = nil
		local windowTimerHandle: any = nil

		local function openThrottleWindow(): ()
			isWindowOpen = true

			windowTimerHandle = Scheduler.Delay(throttleSeconds, function()
				windowTimerHandle = nil
				isWindowOpen = false

				if hasPendingTrailingPayload then
					local payloadToFire = pendingTrailingPayload

					hasPendingTrailingPayload = false
					pendingTrailingPayload = nil

					if not derivedRecord.Destroyed then
						derivedSignal:Fire(payloadToFire)
					end
				end
			end)
		end

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			if not isWindowOpen then
				if leading then
					derivedSignal:Fire(payload)
				elseif trailing then
					hasPendingTrailingPayload = true
					pendingTrailingPayload = payload
				end

				openThrottleWindow()
				return
			end

			if trailing then
				hasPendingTrailingPayload = true
				pendingTrailingPayload = payload
			end
		end)

		Records.attachCleanupCallback(derivedSignal, function()
			if windowTimerHandle ~= nil then
				Scheduler.Cancel(windowTimerHandle)
				windowTimerHandle = nil
			end
		end)

		return derivedSignal
	end

	function signalMethods:Delay(seconds: number): any
		local delaySeconds = Validation.ensureNonNegativeSeconds(seconds, "Signal.Delay: seconds must be non-negative")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local pendingTimerHandles: { any } = {}

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			local timerHandle: any

			timerHandle = Scheduler.Delay(delaySeconds, function()
				for timerIndex = 1, #pendingTimerHandles do
					if pendingTimerHandles[timerIndex] == timerHandle then
						table.remove(pendingTimerHandles, timerIndex)
						break
					end
				end

				if not derivedRecord.Destroyed then
					derivedSignal:Fire(payload)
				end
			end)

			table.insert(pendingTimerHandles, timerHandle)
		end)

		Records.attachCleanupCallback(derivedSignal, function()
			for _, timerHandle in pendingTimerHandles do
				Scheduler.Cancel(timerHandle)
			end

			table.clear(pendingTimerHandles)
		end)

		return derivedSignal
	end

	function signalMethods:BufferCount(count: number, step: number?): any
		local bufferSize = Validation.ensurePositiveInteger(count, "Signal.BufferCount: count must be a positive integer")
		local slideStep = bufferSize

		if step ~= nil then
			slideStep = Validation.ensurePositiveInteger(step, "Signal.BufferCount: step must be a positive integer")
		end

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local bufferedEntries: { { Value: any } } = {}

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			table.insert(bufferedEntries, { Value = payload })

			if #bufferedEntries < bufferSize then
				return
			end

			derivedSignal:Fire(Operators.createPackedArrayFromPresenceAwareBuffer(bufferedEntries, bufferSize))

			for _ = 1, slideStep do
				if #bufferedEntries > 0 then
					table.remove(bufferedEntries, 1)
				end
			end
		end)

		return derivedSignal
	end

	function signalMethods:BufferTime(seconds: number): any
		local bufferSeconds = Validation.ensurePositiveSeconds(seconds, "Signal.BufferTime: seconds must be positive")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local bufferedEntries: { { Value: any } } = {}
		local flushTimerHandle: any = nil

		local function flushBufferedEntries(): ()
			flushTimerHandle = nil

			if #bufferedEntries == 0 then
				return
			end

			local bufferedCount = #bufferedEntries
			local packedArray = Operators.createPackedArrayFromPresenceAwareBuffer(bufferedEntries, bufferedCount)

			table.clear(bufferedEntries)

			if not derivedRecord.Destroyed then
				derivedSignal:Fire(packedArray)
			end
		end

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			table.insert(bufferedEntries, { Value = payload })

			if flushTimerHandle == nil then
				flushTimerHandle = Scheduler.Delay(bufferSeconds, flushBufferedEntries)
			end
		end)

		Records.attachCleanupCallback(derivedSignal, function()
			if flushTimerHandle ~= nil then
				Scheduler.Cancel(flushTimerHandle)
				flushTimerHandle = nil
			end
		end)

		return derivedSignal
	end

	function signalMethods:SampleBy(sampler: any): any
		Operators.validateLiveSignalArgument(Signal, sampler, "Signal.SampleBy: sampler must be a live Signal")

		local derivedSignal = Signal.New()
		local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord
		local samplerRecord = Records.getSignalRecord(sampler) :: SignalRecord

		local hasLatestPayload = false
		local latestPayload: any = nil

		Records.connectDerivedSignal(self, derivedSignal, function(payload: any): ()
			hasLatestPayload = true
			latestPayload = payload
		end)

		local samplerListenerEntry: ListenerEntry = {
			Connected = true,

			Fn = function(_payload: any): ()
				if not derivedRecord.Destroyed and hasLatestPayload then
					local payloadToFire = latestPayload

					hasLatestPayload = false
					latestPayload = nil

					derivedSignal:Fire(payloadToFire)
				end
			end,
		}

		table.insert(samplerRecord.Listeners, samplerListenerEntry)

		table.insert(samplerRecord.CleanupCallbacks, function()
			if not derivedRecord.Destroyed then
				derivedSignal:Destroy()
			end
		end)

		Records.attachCleanupCallback(derivedSignal, function()
			samplerListenerEntry.Connected = false
			Records.compactDisconnectedListenersWhenSafe(samplerRecord)
		end)

		return derivedSignal
	end
end


return table.freeze(Operators)

