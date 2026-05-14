--!strict

local NoErrorSentinel = table.freeze({
	Kind = "ErrorHandler.NoError" :: "ErrorHandler.NoError",
})

local ErrorHandlerModuleSource = debug.info(1, "s") :: string
local MaximumStackLevelsToInspect = 64

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
	Protect: <Result>(callback: (() -> Result) | (() -> ()), moduleName: string, phaseName: string, errorName: string?) -> (boolean, Result?, ReportedError?),

	TakeCollected: () -> { ErrorInfo },
	ClearCollected: () -> (),
}

local ErrorHandler = {} :: ErrorHandlerModule


local Policy: PolicySet = table.freeze({
	Throw = "Throw" :: "Throw",
	Warn = "Warn" :: "Warn",
	Swallow = "Swallow" :: "Swallow",
	Collect = "Collect" :: "Collect",
})

local activePolicy: Policy = Policy.Throw
local activeReporter: Reporter? = nil
local collectedErrorInfoList: { ErrorInfo } = {}
local reporterIsCurrentlyHandlingAnError = false


ErrorHandler.Policy = Policy
ErrorHandler.NoError = NoErrorSentinel


function ErrorHandler.SetPolicy(policy: Policy): ()
	activePolicy = getValidatedPolicy(policy)
end

function ErrorHandler.GetPolicy(): Policy
	return activePolicy
end


function ErrorHandler.SetReporter(reporter: Reporter?): ()
	activeReporter = getValidatedReporter(reporter)
end

function ErrorHandler.GetReporter(): Reporter?
	return activeReporter
end


function ErrorHandler.Report(errorInfo: ErrorInfo): ()
	local validatedErrorInfo = getValidatedErrorInfo(errorInfo)

	callActiveReporterWithoutAllowingRecursiveReporterFailures(validatedErrorInfo)
	applyActivePolicyToErrorInfo(validatedErrorInfo)
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


function ErrorHandler.TakeCollected(): { ErrorInfo }
	local collectedErrorInfoSnapshotList = collectedErrorInfoList
	collectedErrorInfoList = {}

	return collectedErrorInfoSnapshotList
end

function ErrorHandler.ClearCollected(): ()
	collectedErrorInfoList = {}
end


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

function applyActivePolicyToErrorInfo(errorInfo: ErrorInfo): ()
	if activePolicy == Policy.Throw then
		raiseReportedErrorUsingBestAvailableCallerLocation(errorInfo)
	end

	if activePolicy == Policy.Warn then
		warn(createReadableErrorMessage(errorInfo))
		return
	end

	if activePolicy == Policy.Collect then
		table.insert(collectedErrorInfoList, createErrorInfoSnapshot(errorInfo))
		return
	end

	if activePolicy == Policy.Swallow then
		return
	end
end

function raiseReportedErrorUsingBestAvailableCallerLocation(errorInfo: ErrorInfo): never
	error(createReadableErrorMessage(errorInfo), getErrorLevelForFirstCallerOutsideErrorHandlerModule())
end


return table.freeze(ErrorHandler)

