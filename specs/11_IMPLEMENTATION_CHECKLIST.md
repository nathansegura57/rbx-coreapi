# 11 — Implementation Checklist

Use this checklist to verify completeness.

## Global

- [ ] Every file starts with `--!strict`
- [ ] No lowercase aliases
- [ ] No legacy APIs
- [ ] PascalCase public API only
- [ ] No cyclic requires
- [ ] Only Scheduler touches Roblox scheduling/time/frame primitives
- [ ] Runtime callback errors route through ErrorHandler
- [ ] Invalid API usage errors directly
- [ ] Nil presence tracked wherever nil is supported
- [ ] table.freeze not described as security
- [ ] All policies validated at boundary
- [ ] Unknown policy keys error
- [ ] Opaque handles, if used, have protected metatable strings and clear read-only errors

## Connection

- [ ] New
- [ ] IsConnection
- [ ] Connected property
- [ ] Disconnect idempotent
- [ ] disconnectFn ErrorHandler route

## Scheduler

- [ ] Defer
- [ ] Delay
- [ ] Cancel
- [ ] Now
- [ ] OnStep
- [ ] SetDriver
- [ ] ResetDriver
- [ ] callback error wrapping

## ErrorHandler

- [ ] SetPolicy
- [ ] GetPolicy
- [ ] Report
- [ ] SetReporter
- [ ] TakeCollected
- [ ] reporter errors do not recurse

## Context

- [ ] Root
- [ ] Key
- [ ] IsContext
- [ ] Require
- [ ] Maybe
- [ ] Has
- [ ] Set
- [ ] Provide
- [ ] ProvideLazy
- [ ] Layer
- [ ] Pick/View
- [ ] Readonly
- [ ] Destroy
- [ ] IsDestroyed
- [ ] OnDestroy
- [ ] lazy nil caching
- [ ] lazy cycle detection
- [ ] view source destroy behavior

## Signal

- [ ] New
- [ ] Never
- [ ] After
- [ ] Every
- [ ] FromRoblox
- [ ] Merge
- [ ] Zip with nil support
- [ ] Race
- [ ] Sequence
- [ ] IsSignal
- [ ] Connect
- [ ] Once
- [ ] Fire
- [ ] Wait
- [ ] DisconnectAll
- [ ] Destroy
- [ ] IsDestroyed
- [ ] all operators
- [ ] replay policies
- [ ] source destroy destroys derived
- [ ] derived destroy disconnects source

## Store

- [ ] Value
- [ ] Const
- [ ] Derive
- [ ] Select
- [ ] Combine
- [ ] AllTruthy
- [ ] AnyTruthy
- [ ] Match
- [ ] Readonly
- [ ] IsStore
- [ ] Batch
- [ ] Transaction
- [ ] Snapshot
- [ ] Restore
- [ ] History
- [ ] Get/Peek
- [ ] Set/Update
- [ ] Subscribe options
- [ ] Changed
- [ ] Wait
- [ ] DisconnectAll
- [ ] recursive derived destruction
- [ ] duplicate name rules

## Task

- [ ] Start
- [ ] Defer
- [ ] Delay
- [ ] Sleep
- [ ] Resolved/Rejected/Cancelled
- [ ] Timeout
- [ ] Retry
- [ ] All/Race/Any/AllSettled
- [ ] FromRoblox
- [ ] Group
- [ ] IsTask/IsToken/IsGroup
- [ ] token cancellation hooks
- [ ] Await token cancels await only
- [ ] nil result preservation
- [ ] group Destroy

## Rule

- [ ] New
- [ ] IsRule
- [ ] DefaultPolicy
- [ ] ValidatePolicy
- [ ] SetTracer
- [ ] On/When/Run/Policy/WithContext
- [ ] Attach FSM/FSM Mode only
- [ ] Enable/Disable/Destroy
- [ ] IsEnabled/IsDestroyed
- [ ] Metrics/ResetMetrics
- [ ] debounce/throttle nil support
- [ ] all concurrency modes
- [ ] Once resets enable count
- [ ] Retry integration

## FSM

- [ ] New
- [ ] IsFSM/IsMode
- [ ] DefaultPolicy/ValidatePolicy
- [ ] SetTracer
- [ ] Context
- [ ] Mode/HasMode/GetMode
- [ ] Start/Switch/CanSwitch
- [ ] Current/IsActive/InMode/Path
- [ ] History/SwitchToHistory/ClearHistory
- [ ] Snapshot/Restore
- [ ] OnTransition/WaitForTransition
- [ ] Policy before start only
- [ ] Destroy order correct
- [ ] ActiveStore readonly
- [ ] IsActiveStore readonly
- [ ] Mode APIs
- [ ] parent cycle prevention
- [ ] re-parent rejection
- [ ] guard priority stable
- [ ] OnUpdate via Scheduler.OnStep
