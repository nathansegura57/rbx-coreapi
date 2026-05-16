--!strict

local NoErrorSentinel = table.freeze({
	Kind = "ErrorHandler.NoError" :: "ErrorHandler.NoError",
})

local ErrorHandlerModuleSource = debug.info(1, "s") :: string
local MaximumStackLevelsToInspect = 64

-- Derive the Kernel-wide path prefix so RaiseUsageError can skip any Kernel
-- module frame, not only ErrorHandler's own frames.
local KernelRootPrefix: string = (function(): string
	local lastDotPosition = string.find(ErrorHandlerModuleSource, "%.([^%.]*)$")
	if lastDotPosition == nil then
		return ErrorHandlerModuleSource
	end
	return string.sub(ErrorHandlerModuleSource, 1, lastDotPosition)
end)()


export type NoErrorSentinel = typeof(NoErrorSentinel)
export type ReportedError = unknown

export type Policy = "Throw" | "Warn" | "Swallow" | "Collect"

export type PolicySet = {
	Throw: "Throw",
	Warn: "Warn",
	Swallow: "Swallow",
	Collect: "Collect",
}

export type ErrorInfo = {
	Module: string,
	Phase: string,
	Name: string?,
	Message: string?,
	Error: ReportedError,
}

export type Reporter = (errorInfo: ErrorInfo) -> ()

export type ErrorHandlerModule = {
	Policy: PolicySet,
	NoError: NoErrorSentinel,

	SetPolicy: (policy: Policy) -> (),
	GetPolicy: () -> Policy,

	SetReporter: (reporter: Reporter?) -> (),
	GetReporter: () -> Reporter?,

	Report: (errorInfo: ErrorInfo) -> (),
	ReportWithPolicy: (errorInfo: ErrorInfo, policy: Policy) -> (),
	Protect: <Result>(
		callback: (() -> Result) | (() -> ()),
		moduleName: string,
		phaseName: string,
		errorName: string?
	) -> (boolean, Result?, ReportedError?),

	RaiseUsageError: (message: string) -> never,

	TakeCollected: () -> { ErrorInfo },
	ClearCollected: () -> (),
}

local ErrorHandler = {} :: ErrorHandlerModule


-- ── Enum table ────────────────────────────────────────────────────────────────

local throwPolicy: "Throw" = "Throw"
local warnPolicy: "Warn" = "Warn"
local swallowPolicy: "Swallow" = "Swallow"
local collectPolicy: "Collect" = "Collect"

local Policy: PolicySet = table.freeze({
	Throw = throwPolicy,
	Warn = warnPolicy,
	Swallow = swallowPolicy,
	Collect = collectPolicy,
})

-- ── Active state ──────────────────────────────────────────────────────────────

local activePolicy: Policy = Policy.Throw
local activeReporter: Reporter? = nil
local collectedErrorInfoList: { ErrorInfo } = {}
local reporterIsCurrentlyHandlingAnError = false


-- ── Public state ──────────────────────────────────────────────────────────────

ErrorHandler.Policy = Policy
ErrorHandler.NoError = NoErrorSentinel


-- ── Policy ────────────────────────────────────────────────────────────────────

function ErrorHandler.SetPolicy(policy: Policy): ()
	activePolicy = getValidatedPolicy(policy)
end

function ErrorHandler.GetPolicy(): Policy
	return activePolicy
end


-- ── Reporter ──────────────────────────────────────────────────────────────────

function ErrorHandler.SetReporter(reporter: Reporter?): ()
	activeReporter = getValidatedReporter(reporter)
end

function ErrorHandler.GetReporter(): Reporter?
	return activeReporter
end


-- ── Report and protect ────────────────────────────────────────────────────────

function ErrorHandler.Report(errorInfo: ErrorInfo): ()
	local validatedErrorInfo = getValidatedErrorInfo(errorInfo)

	callActiveReporterWithoutAllowingRecursiveReporterFailures(validatedErrorInfo)
	applyPolicyToErrorInfo(validatedErrorInfo, activePolicy)
end

function ErrorHandler.ReportWithPolicy(errorInfo: ErrorInfo, policy: Policy): ()
	local validatedErrorInfo = getValidatedErrorInfo(errorInfo)

	callActiveReporterWithoutAllowingRecursiveReporterFailures(validatedErrorInfo)
	applyPolicyToErrorInfo(validatedErrorInfo, policy)
end

function ErrorHandler.Protect<Result>(
	callback: (() -> Result) | (() -> ()),
	moduleName: string,
	phaseName: string,
	errorName: string?
): (boolean, Result?, ReportedError?)
	local callbackSucceeded, callbackResultOrError = pcall(callback)

	if callbackSucceeded then
		return true, callbackResultOrError :: Result, nil
	end

	ErrorHandler.Report({
		Module = moduleName,
		Phase = phaseName,
		Name = errorName,
		Error = callbackResultOrError,
	})

	return false, nil, callbackResultOrError
end


-- ── Usage error raiser ────────────────────────────────────────────────────────

-- Walks the call stack and raises at the first frame that does not belong to
-- any Kernel module (identified by KernelRootPrefix) and is not a C boundary.
-- Falls back to level 2 if no user frame is found.
function ErrorHandler.RaiseUsageError(message: string): never
	for stackLevel = 2, MaximumStackLevelsToInspect do
		local frameSource = debug.info(stackLevel, "s")

		if frameSource == nil then
			break
		end

		if frameSource ~= "=[C]"
			and string.sub(frameSource, 1, #KernelRootPrefix) ~= KernelRootPrefix
		then
			error(message, stackLevel)
		end
	end

	error(message, 2)
end


-- ── Collected errors ──────────────────────────────────────────────────────────

function ErrorHandler.TakeCollected(): { ErrorInfo }
	local collectedErrorInfoSnapshotList = collectedErrorInfoList
	collectedErrorInfoList = {}

	return collectedErrorInfoSnapshotList
end

function ErrorHandler.ClearCollected(): ()
	collectedErrorInfoList = {}
end


-- ── Internal: usage error for ErrorHandler's own validation ──────────────────

function raiseErrorHandlerUsageError(message: string): never
	error(message, getErrorLevelForFirstCallerOutsideErrorHandlerModule())
end

function getErrorLevelForFirstCallerOutsideErrorHandlerModule(): number
	local firstStackLevelOutsideThisHelper = 2
	local firstStackLevelOutsideErrorHandlerModule = 3

	for inspectedStackLevel = firstStackLevelOutsideErrorHandlerModule, MaximumStackLevelsToInspect do
		local inspectedSource = debug.info(inspectedStackLevel, "s")

		if inspectedSource == nil then
			return firstStackLevelOutsideThisHelper
		end

		if inspectedSource ~= ErrorHandlerModuleSource then
			return inspectedStackLevel - 1
		end
	end

	return firstStackLevelOutsideThisHelper
end


-- ── Argument validation ───────────────────────────────────────────────────────

function getValidatedPolicy(untrustedPolicy: unknown): Policy
	if untrustedPolicy == Policy.Throw then
		return Policy.Throw
	end

	if untrustedPolicy == Policy.Warn then
		return Policy.Warn
	end

	if untrustedPolicy == Policy.Swallow then
		return Policy.Swallow
	end

	if untrustedPolicy == Policy.Collect then
		return Policy.Collect
	end

	return raiseErrorHandlerUsageError(`ErrorHandler.SetPolicy: invalid policy '{tostring(untrustedPolicy)}'`)
end

function getValidatedReporter(untrustedReporter: unknown?): Reporter?
	if untrustedReporter == nil then
		return nil
	end

	if typeof(untrustedReporter) ~= "function" then
		raiseErrorHandlerUsageError("ErrorHandler.SetReporter: reporter must be a function or nil")
	end

	return untrustedReporter :: Reporter
end

function getValidatedErrorInfo(untrustedErrorInfo: unknown): ErrorInfo
	if typeof(untrustedErrorInfo) ~= "table" then
		raiseErrorHandlerUsageError("ErrorHandler.Report: errorInfo must be a table")
	end

	local errorInfoTable = untrustedErrorInfo :: { [string]: unknown }

	return {
		Module = getValidatedModuleName(errorInfoTable),
		Phase = getValidatedPhaseName(errorInfoTable),
		Name = getValidatedOptionalErrorName(errorInfoTable),
		Message = getValidatedOptionalMessage(errorInfoTable),
		Error = getValidatedReportedError(errorInfoTable),
	}
end


function getRequiredStringFieldFromErrorInfoTable(
	errorInfoTable: { [string]: unknown },
	fieldName: string,
	usageErrorMessage: string
): string
	local untrustedFieldValue = errorInfoTable[fieldName]

	if typeof(untrustedFieldValue) == "string" then
		return untrustedFieldValue
	end

	return raiseErrorHandlerUsageError(usageErrorMessage)
end

function getOptionalStringFieldFromErrorInfoTable(
	errorInfoTable: { [string]: unknown },
	fieldName: string,
	usageErrorMessage: string
): string?
	local untrustedFieldValue = errorInfoTable[fieldName]

	if untrustedFieldValue == nil then
		return nil
	end

	if typeof(untrustedFieldValue) == "string" then
		return untrustedFieldValue
	end

	return raiseErrorHandlerUsageError(usageErrorMessage)
end

function getValidatedModuleName(errorInfoTable: { [string]: unknown }): string
	return getRequiredStringFieldFromErrorInfoTable(
		errorInfoTable,
		"Module",
		"ErrorHandler.Report: Module must be a string"
	)
end

function getValidatedPhaseName(errorInfoTable: { [string]: unknown }): string
	return getRequiredStringFieldFromErrorInfoTable(
		errorInfoTable,
		"Phase",
		"ErrorHandler.Report: Phase must be a string"
	)
end

function getValidatedOptionalErrorName(errorInfoTable: { [string]: unknown }): string?
	return getOptionalStringFieldFromErrorInfoTable(
		errorInfoTable,
		"Name",
		"ErrorHandler.Report: Name must be a string or nil"
	)
end

function getValidatedOptionalMessage(errorInfoTable: { [string]: unknown }): string?
	return getOptionalStringFieldFromErrorInfoTable(
		errorInfoTable,
		"Message",
		"ErrorHandler.Report: Message must be a string or nil"
	)
end

function getValidatedReportedError(errorInfoTable: { [string]: unknown }): ReportedError
	local reportedError = errorInfoTable.Error

	if reportedError == nil then
		raiseErrorHandlerUsageError("ErrorHandler.Report: Error must be a captured error value or ErrorHandler.NoError")
	end

	return reportedError
end


-- ── Error formatting ──────────────────────────────────────────────────────────

function createErrorInfoSnapshot(errorInfo: ErrorInfo): ErrorInfo
	return {
		Module = errorInfo.Module,
		Phase = errorInfo.Phase,
		Name = errorInfo.Name,
		Message = errorInfo.Message,
		Error = errorInfo.Error,
	}
end

function createReadableErrorLocation(errorInfo: ErrorInfo): string
	if errorInfo.Name == nil then
		return `{errorInfo.Module}.{errorInfo.Phase}`
	end

	return `{errorInfo.Module}.{errorInfo.Phase}[{errorInfo.Name}]`
end

function createReadableErrorReason(errorInfo: ErrorInfo): string
	if errorInfo.Message ~= nil then
		return errorInfo.Message
	end

	if errorInfo.Error == NoErrorSentinel then
		return "No captured error value"
	end

	return tostring(errorInfo.Error)
end

function createReadableErrorMessage(errorInfo: ErrorInfo): string
	return `{createReadableErrorLocation(errorInfo)}: {createReadableErrorReason(errorInfo)}`
end


-- ── Reporter invocation ───────────────────────────────────────────────────────

function reporterCallSucceeded(reporter: Reporter, errorInfo: ErrorInfo): (boolean, unknown?)
	local reporterSucceeded, reporterError = pcall(function()
		reporter(errorInfo)
	end)

	return reporterSucceeded, reporterError
end

function callActiveReporterWithoutAllowingRecursiveReporterFailures(errorInfo: ErrorInfo): ()
	local reporter = activeReporter

	if reporter == nil then
		return
	end

	if reporterIsCurrentlyHandlingAnError then
		return
	end

	reporterIsCurrentlyHandlingAnError = true

	local reporterSucceeded, reporterError =
		reporterCallSucceeded(reporter, createErrorInfoSnapshot(errorInfo))

	reporterIsCurrentlyHandlingAnError = false

	if not reporterSucceeded then
		warn(`ErrorHandler: reporter failed: {tostring(reporterError)}`)
	end
end

function applyPolicyToErrorInfo(errorInfo: ErrorInfo, policy: Policy): ()
	if policy == Policy.Throw then
		raiseReportedErrorUsingBestAvailableCallerLocation(errorInfo)
	end

	if policy == Policy.Warn then
		warn(createReadableErrorMessage(errorInfo))
		return
	end

	if policy == Policy.Collect then
		table.insert(collectedErrorInfoList, createErrorInfoSnapshot(errorInfo))
		return
	end

	if policy == Policy.Swallow then
		return
	end
end

function raiseReportedErrorUsingBestAvailableCallerLocation(errorInfo: ErrorInfo): never
	error(createReadableErrorMessage(errorInfo), getErrorLevelForFirstCallerOutsideErrorHandlerModule())
end


return table.freeze(ErrorHandler)
