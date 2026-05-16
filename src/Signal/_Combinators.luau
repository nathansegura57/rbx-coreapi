--!strict

local ErrorHandler = require(script.Parent.Parent.ErrorHandler)
local Scheduler = require(script.Parent.Parent.Scheduler)

local Records = require(script.Parent._Records)
local Validation = require(script.Parent._Validation)
local Types = require(script.Parent._Types)

local Combinators = {}

type ListenerEntry = Types.ListenerEntry
type SignalRecord = Types.SignalRecord
type SignalModule = Types.SignalModule


function Combinators.ensureDenseArrayOfLiveSignals(Signal: SignalModule, signals: any, usageErrorMessage: string): ()
	if type(signals) ~= "table" or #signals == 0 then
		ErrorHandler.RaiseUsageError(usageErrorMessage)
	end

	for signalIndex = 1, #signals do
		local signal = signals[signalIndex]

		if not Signal.IsSignal(signal) then
			ErrorHandler.RaiseUsageError(usageErrorMessage)
		end

		local signalRecord = Records.getSignalRecord(signal)

		if signalRecord == nil or signalRecord.Destroyed then
			ErrorHandler.RaiseUsageError(usageErrorMessage)
		end
	end
end

function Combinators.getValidatedSequenceOptions(options: any): (number, number, number, number, boolean, boolean)
	local minimumTimeBetweenSteps = 0
	local maximumTimeBetweenSteps = math.huge
	local minimumTotalTime = 0
	local maximumTotalTime = math.huge
	local resetOnMismatch = true
	local fireOnMismatch = false

	if options == nil then
		return minimumTimeBetweenSteps, maximumTimeBetweenSteps, minimumTotalTime, maximumTotalTime, resetOnMismatch, fireOnMismatch
	end

	if type(options) ~= "table" then
		ErrorHandler.RaiseUsageError("Signal.Sequence: opts must be a table or nil")
	end

	if options.MinTimeBetween ~= nil then
		minimumTimeBetweenSteps = Validation.ensureNonNegativeSeconds(options.MinTimeBetween, "Signal.Sequence: timing options must be non-negative")
	end

	if options.MaxTimeBetween ~= nil then
		maximumTimeBetweenSteps = Validation.ensureNonNegativeSeconds(options.MaxTimeBetween, "Signal.Sequence: timing options must be non-negative")
	end

	if options.MinTotalTime ~= nil then
		minimumTotalTime = Validation.ensureNonNegativeSeconds(options.MinTotalTime, "Signal.Sequence: timing options must be non-negative")
	end

	if options.MaxTotalTime ~= nil then
		maximumTotalTime = Validation.ensureNonNegativeSeconds(options.MaxTotalTime, "Signal.Sequence: timing options must be non-negative")
	end

	if options.ResetOnMismatch ~= nil then
		if type(options.ResetOnMismatch) ~= "boolean" then
			ErrorHandler.RaiseUsageError("Signal.Sequence: ResetOnMismatch must be a boolean or nil")
		end

		resetOnMismatch = options.ResetOnMismatch
	end

	if options.FireOnMismatch ~= nil then
		if type(options.FireOnMismatch) ~= "boolean" then
			ErrorHandler.RaiseUsageError("Signal.Sequence: FireOnMismatch must be a boolean or nil")
		end

		fireOnMismatch = options.FireOnMismatch
	end

	if maximumTimeBetweenSteps < minimumTimeBetweenSteps then
		ErrorHandler.RaiseUsageError("Signal.Sequence: MaxTimeBetween must be >= MinTimeBetween")
	end

	if maximumTotalTime < minimumTotalTime then
		ErrorHandler.RaiseUsageError("Signal.Sequence: MaxTotalTime must be >= MinTotalTime")
	end

	return minimumTimeBetweenSteps, maximumTimeBetweenSteps, minimumTotalTime, maximumTotalTime, resetOnMismatch, fireOnMismatch
end


function Combinators.mergeSignals(Signal: SignalModule, signals: { any }): any
	Combinators.ensureDenseArrayOfLiveSignals(Signal, signals, "Signal.Merge: signals must be a non-empty dense array of Signals")

	local derivedSignal = Signal.New()
	local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord

	for _, sourceSignal in signals do
		Records.connectDerivedSignal(sourceSignal, derivedSignal, function(payload: any): ()
			if not derivedRecord.Destroyed then
				derivedSignal:Fire(payload)
			end
		end)
	end

	return derivedSignal
end

function Combinators.zipSignals(Signal: SignalModule, signals: { any }): any
	Combinators.ensureDenseArrayOfLiveSignals(Signal, signals, "Signal.Zip: signals must be a non-empty dense array of Signals")

	local signalCount = #signals
	local derivedSignal = Signal.New()
	local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord

	local filledSlots: { boolean } = table.create(signalCount, false)
	local payloadSlots: { any } = table.create(signalCount)

	for sourceIndex, sourceSignal in signals do
		local slotIndex = sourceIndex

		Records.connectDerivedSignal(sourceSignal, derivedSignal, function(payload: any): ()
			if derivedRecord.Destroyed or filledSlots[slotIndex] then
				return
			end

			filledSlots[slotIndex] = true
			payloadSlots[slotIndex] = payload

			for requiredIndex = 1, signalCount do
				if not filledSlots[requiredIndex] then
					return
				end
			end

			local packedArray = table.create(signalCount)

			for payloadIndex = 1, signalCount do
				packedArray[payloadIndex] = payloadSlots[payloadIndex]
				filledSlots[payloadIndex] = false
				payloadSlots[payloadIndex] = nil
			end

			(packedArray :: any).n = signalCount

			derivedSignal:Fire(packedArray)
		end)
	end

	return derivedSignal
end

function Combinators.raceSignals(Signal: SignalModule, signals: { any }): any
	Combinators.ensureDenseArrayOfLiveSignals(Signal, signals, "Signal.Race: signals must be a non-empty dense array of Signals")

	local derivedSignal = Signal.New()
	local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord

	local winningSignal: any = nil
	local listenerPairs: { { Listener: ListenerEntry, Source: any } } = {}

	for _, sourceSignal in signals do
		local currentSourceSignal = sourceSignal

		local listenerEntry: ListenerEntry

		listenerEntry = {
			Connected = true,

			Fn = function(payload: any): ()
				if derivedRecord.Destroyed then
					return
				end

				if winningSignal == nil then
					winningSignal = currentSourceSignal

					for _, listenerPair in listenerPairs do
						if listenerPair.Source ~= currentSourceSignal then
							listenerPair.Listener.Connected = false
						end
					end
				end

				if winningSignal == currentSourceSignal then
					derivedSignal:Fire(payload)
				end
			end,
		}

		local sourceRecord = Records.getSignalRecord(currentSourceSignal) :: SignalRecord

		table.insert(sourceRecord.Listeners, listenerEntry)
		table.insert(listenerPairs, {
			Listener = listenerEntry,
			Source = currentSourceSignal,
		})

		table.insert(sourceRecord.CleanupCallbacks, function()
			if not derivedRecord.Destroyed and (winningSignal == nil or winningSignal == currentSourceSignal) then
				derivedSignal:Destroy()
			end
		end)
	end

	Records.attachCleanupCallback(derivedSignal, function()
		for _, listenerPair in listenerPairs do
			listenerPair.Listener.Connected = false
		end

		table.clear(listenerPairs)
	end)

	return derivedSignal
end

function Combinators.sequenceSignals(Signal: SignalModule, signals: { any }, options: any): any
	Combinators.ensureDenseArrayOfLiveSignals(Signal, signals, "Signal.Sequence: signals must be a non-empty dense array of Signals")

	local minimumTimeBetweenSteps, maximumTimeBetweenSteps, minimumTotalTime, maximumTotalTime, resetOnMismatch, fireOnMismatch =
		Combinators.getValidatedSequenceOptions(options)

	local derivedSignal = Signal.New()
	local derivedRecord = Records.getSignalRecord(derivedSignal) :: SignalRecord

	local completedStepCount = 0
	local sequenceStartedAt = 0
	local previousStepCompletedAt = 0
	local sequenceLength = #signals

	local function resetSequenceProgress(): ()
		completedStepCount = 0
		sequenceStartedAt = 0
		previousStepCompletedAt = 0
	end

	local function fireMismatchIfRequested(elapsedTime: number): ()
		if fireOnMismatch then
			derivedSignal:Fire({
				Time = elapsedTime,
				Completed = false,
			})
		end
	end

	local uniqueSources: { [any]: boolean } = {}

	for _, sourceSignal in signals do
		if uniqueSources[sourceSignal] then
			continue
		end

		uniqueSources[sourceSignal] = true

		Records.connectDerivedSignal(sourceSignal, derivedSignal, function(_payload: any): ()
			if derivedRecord.Destroyed then
				return
			end

			local currentTime = Scheduler.Now()
			local expectedSignal = signals[completedStepCount + 1]

			if sourceSignal ~= expectedSignal then
				local elapsedTime = if completedStepCount > 0 then currentTime - sequenceStartedAt else 0

				fireMismatchIfRequested(elapsedTime)

				if resetOnMismatch then
					resetSequenceProgress()
				end

				return
			end

			if completedStepCount > 0 then
				local timeSincePreviousStep = currentTime - previousStepCompletedAt

				if timeSincePreviousStep < minimumTimeBetweenSteps or timeSincePreviousStep > maximumTimeBetweenSteps then
					local elapsedTime = currentTime - sequenceStartedAt

					fireMismatchIfRequested(elapsedTime)

					if resetOnMismatch then
						resetSequenceProgress()
					end

					return
				end
			end

			if completedStepCount == 0 then
				sequenceStartedAt = currentTime
			end

			previousStepCompletedAt = currentTime
			completedStepCount += 1

			local timeElapsed = currentTime - sequenceStartedAt

			if timeElapsed > maximumTotalTime then
				fireMismatchIfRequested(timeElapsed)

				if resetOnMismatch then
					resetSequenceProgress()
				end

				return
			end

			if completedStepCount < sequenceLength then
				return
			end

			if timeElapsed >= minimumTotalTime then
				derivedSignal:Fire({
					Time = timeElapsed,
					Completed = true,
				})

				resetSequenceProgress()
			else
				fireMismatchIfRequested(timeElapsed)

				if resetOnMismatch then
					resetSequenceProgress()
				end
			end
		end)
	end

	return derivedSignal
end


return table.freeze(Combinators)

