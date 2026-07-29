--!strict
-- Optional type definitions for TaskRuntime consumers.

export type CallbackMode = "protected" | "direct"

export type TaskError = {
	Code: string,
	Message: string,
	Cause: any?,
	TaskId: number?,
	TaskName: string?,
	TaskKind: string?,
	Attempt: number?,
	Metadata: { [any]: any },
	ParentTaskId: number?,
	ScopeName: string?,
	Traceback: string?,
	ToString: (self: TaskError) -> string,
}

export type TaskOutcome = {
	Status: string,
	Success: boolean,
	Values: { [number]: any, n: number }?,
	Error: TaskError?,
	CancellationReason: string?,
	Task: TaskHandle,
	IsSuccess: (self: TaskOutcome) -> boolean,
	Unpack: (self: TaskOutcome) -> ...any,
	ThrowIfFailed: (self: TaskOutcome) -> ...any,
}

export type CallbackConnection = {
	Connected: boolean,
	Disconnect: (self: CallbackConnection) -> boolean,
	Destroy: (self: CallbackConnection) -> boolean,
}

export type DeadlineHandle = {
	Id: number,
	At: number,
	Label: string?,
	Active: boolean,
	Cancel: (self: DeadlineHandle) -> boolean,
	Disconnect: (self: DeadlineHandle) -> boolean,
	Destroy: (self: DeadlineHandle) -> boolean,
}

export type CancellationToken = {
	IsCancelled: (self: CancellationToken) -> boolean,
	GetReason: (self: CancellationToken) -> string?,
	ThrowIfCancelled: (self: CancellationToken) -> (),
	OnCancel: (self: CancellationToken, callback: (string?) -> ()) -> CallbackConnection,
	Wait: (self: CancellationToken, seconds: number) -> boolean,
}

export type CancellationSource = {
	Token: CancellationToken,
	Cancel: (self: CancellationSource, reason: string?) -> boolean,
	IsCancelled: (self: CancellationSource) -> boolean,
	Destroy: (self: CancellationSource, reason: string?) -> boolean,
}

export type TaskHandle = {
	Id: number,
	Kind: string,
	Name: string,
	State: string,
	Cancelled: boolean,
	CancelReason: string?,
	CreatedAt: number,
	StartedAt: number?,
	FinishedAt: number?,
	Error: string?,
	ErrorInfo: TaskError?,
	Results: { [number]: any, n: number }?,
	Iterations: number,
	SkippedIntervals: number,
	Metadata: { [any]: any },
	Token: CancellationToken,
	ParentTaskId: number?,
	OwnerScopeName: string?,
	DeadlineAt: number?,
	SetName: (self: TaskHandle, name: string) -> TaskHandle,
	SetMetadata: (self: TaskHandle, key: any, value: any) -> TaskHandle,
	GetMetadata: (self: TaskHandle, key: any) -> any,
	GetElapsedTime: (self: TaskHandle) -> number,
	GetOutcome: (self: TaskHandle) -> TaskOutcome,
	Cancel: (self: TaskHandle, reason: string?) -> boolean,
	CancelAfter: (self: TaskHandle, seconds: number, reason: string?) -> DeadlineHandle?,
	IsCancelled: (self: TaskHandle) -> boolean,
	IsCancellationRequested: (self: TaskHandle) -> boolean,
	IsDone: (self: TaskHandle) -> boolean,
	OnComplete: (self: TaskHandle, callback: (TaskHandle) -> ()) -> CallbackConnection,
	Await: (self: TaskHandle, timeoutSeconds: number?) -> ...any,
	AwaitOutcome: (self: TaskHandle, timeoutSeconds: number?) -> TaskOutcome,
	Then: (self: TaskHandle, callback: (CancellationToken, ...any) -> ...any) -> TaskHandle,
	Catch: (self: TaskHandle, callback: (CancellationToken, TaskError?, string?, TaskOutcome) -> ...any) -> TaskHandle,
	Finally: (self: TaskHandle, callback: (CancellationToken, TaskOutcome) -> ()) -> TaskHandle,
}

export type CleanupError = {
	Code: string,
	Message: string,
	Resource: any,
	CleanupMethod: any,
	Cause: any,
	ScopeName: string,
	Timestamp: number,
}

export type CleanupScope = {
	Name: string,
	CancelOnTaskFailure: boolean,
	CleanupTimeout: number?,
	ResourceCleanupTimeout: number?,
	IsDestroyed: (self: CleanupScope) -> boolean,
	IsCleanupComplete: (self: CleanupScope) -> boolean,
	GetCount: (self: CleanupScope) -> number,
	GetCleanupErrors: (self: CleanupScope) -> { CleanupError },
	HasCleanupErrors: (self: CleanupScope) -> boolean,
	GetTaskFailures: (self: CleanupScope) -> { any },
	OnCleanupComplete: (self: CleanupScope, callback: (CleanupScope) -> ()) -> CallbackConnection,
	Add: (self: CleanupScope, resource: any, cleanupMethod: any?, options: any?) -> any,
	Set: (self: CleanupScope, key: any, resource: any, cleanupMethod: any?, options: any?) -> any,
	Get: (self: CleanupScope, key: any) -> any,
	Has: (self: CleanupScope, key: any) -> boolean,
	Remove: (self: CleanupScope, key: any, shouldCleanup: boolean?, reason: string?) -> any,
	Connect: (self: CleanupScope, signal: any, callback: (...any) -> ()) -> any,
	Spawn: (self: CleanupScope, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	Defer: (self: CleanupScope, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	Delay: (self: CleanupScope, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	Every: (self: CleanupScope, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	WithTimeout: (self: CleanupScope, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	Retry: (self: CleanupScope, attempts: number, callback: (CancellationToken, number, ...any) -> ...any, options: any?, ...any) -> TaskHandle,
	Child: (self: CleanupScope, name: string?, options: any?) -> CleanupScope,
	Run: (self: CleanupScope, callback: (TaskContext, CancellationToken, ...any) -> ...any, options: any?, ...any) -> TaskHandle,
	Cleanup: (self: CleanupScope, reason: string?) -> boolean,
	Destroy: (self: CleanupScope, reason: string?) -> boolean,
	DestroyAndAwait: (self: CleanupScope, reason: string?, timeoutSeconds: number?) -> ...any,
}

export type TaskContext = {
	Name: string,
	Scope: CleanupScope,
	Source: CancellationSource,
	Token: CancellationToken,
	Closed: boolean,
	RootTaskId: number?,
	Spawn: (self: TaskContext, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	Defer: (self: TaskContext, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	Delay: (self: TaskContext, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	Every: (self: TaskContext, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	WithTimeout: (self: TaskContext, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	Retry: (self: TaskContext, attempts: number, callback: (CancellationToken, number, ...any) -> ...any, options: any?, ...any) -> TaskHandle,
	Child: (self: TaskContext, name: string?, options: any?) -> TaskContext,
	Cancel: (self: TaskContext, reason: string?) -> boolean,
	Close: (self: TaskContext, reason: string?, timeoutSeconds: number?) -> ...any,
}

export type Semaphore = {
	Limit: number,
	Available: number,
	GetWaitingCount: (self: Semaphore) -> number,
	Acquire: (self: Semaphore, token: CancellationToken?, timeoutSeconds: number?) -> (boolean, string?),
	Release: (self: Semaphore, count: number?) -> boolean,
	WithPermit: (self: Semaphore, token: CancellationToken?, callback: (...any) -> ...any, timeoutSeconds: number?, ...any) -> ...any,
}

export type TaskQueue = {
	Name: string,
	Scope: CleanupScope?,
	Semaphore: Semaphore,
	Closed: boolean,
	Add: (self: TaskQueue, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	GetActiveCount: (self: TaskQueue) -> number,
	Close: (self: TaskQueue, reason: string?) -> boolean,
	Destroy: (self: TaskQueue, reason: string?) -> boolean,
}

export type Runtime = {
	spawn: (self: Runtime, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	defer: (self: Runtime, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	delay: (self: Runtime, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	every: (self: Runtime, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	withTimeout: (self: Runtime, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	retry: (self: Runtime, attempts: number, callback: (CancellationToken, number, ...any) -> ...any, options: any?, ...any) -> TaskHandle,
	all: (self: Runtime, handles: { TaskHandle }, options: any?) -> TaskHandle,
	settle: (self: Runtime, handles: { TaskHandle }) -> TaskHandle,
	race: (self: Runtime, handles: { TaskHandle }, options: any?) -> TaskHandle,
	any: (self: Runtime, handles: { TaskHandle }, options: any?) -> TaskHandle,
	map: (self: Runtime, items: { any }, callback: (CancellationToken, any, number) -> ...any, options: any?) -> TaskHandle,
	mapLimit: (self: Runtime, items: { any }, concurrency: number, callback: (CancellationToken, any, number) -> ...any, options: any?) -> TaskHandle,
	scope: (self: Runtime, name: string?, options: any?) -> CleanupScope,
	context: (self: Runtime, name: string?, options: any?) -> TaskContext,
	semaphore: (self: Runtime, limit: number) -> Semaphore,
	queue: (self: Runtime, concurrency: number, options: any?) -> TaskQueue,
	debounce: (self: Runtime, key: any, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> TaskHandle,
	throttle: (self: Runtime, key: any, seconds: number, callback: (CancellationToken, ...any) -> ...any, ...any) -> (TaskHandle?, TaskHandle?),
	getCallbackMode: (self: Runtime) -> CallbackMode,
	getSnapshot: (self: Runtime) -> any,
	getHistory: (self: Runtime) -> { any },
	getStats: (self: Runtime) -> { [string]: any },
	configureDiagnostics: (self: Runtime, options: any?) -> any,
	shutdown: (self: Runtime, reason: string?) -> boolean,
}

return {}
