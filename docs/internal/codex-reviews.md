# Codex reviews — `fix/help-command-freeze`

PR: [apple/container#1454](https://github.com/apple/container/pull/1454)
Branch diff vs `main`: 5 files, +312 / -39

Two automated reviews were run against this branch via the `codex` plugin. Their output is preserved verbatim below for the record.

---

## 1. `/codex:review` — pass

Standard review pass. Did not flag any introduced defect.

> # Codex Review
>
> Target: branch diff against main
>
> The changes address the help-path daemon dependency and make XPC timeouts able to resume without invalidating reusable connections. I did not find any discrete introduced bug that should block the patch.

---

## 2. `/codex:adversarial-review` — needs-attention

Adversarial pass that explicitly challenges design choices, tradeoffs, and assumptions. Surfaced a high-severity design concern about timed-out XPC requests under a slow-but-not-dead daemon.

> # Codex Adversarial Review
>
> Target: branch diff against main
> Verdict: needs-attention
>
> No-ship: the generic XPC timeout fix can report failure while mutating requests are still in flight and then let callers reuse the same client as if the connection state were clean.
>
> Findings:
> - [high] Timed-out XPC requests can still mutate state after callers retry (Sources/ContainerXPC/XPCClient.swift:94-114)
>   Lines 94-114 send the XPC message, then race it with an unstructured timeout task that only resumes the Swift continuation; it does not cancel the underlying XPC request, invalidate/rebuild the connection, or surface a late successful reply. Because this is the generic `XPCClient.send` path, the risk is not limited to health checks: mutating callers that use `responseTimeout` can receive `.timeout`, retry or proceed with cleanup, while the original server-side operation may later commit. That creates duplicate or out-of-order container/network state under a slow-but-not-dead daemon. This is an inference from the generic send behavior plus the documented late-reply drop semantics.
>   Recommendation: Do not drop late completion generically for mutating requests. Either restrict this timeout behavior to idempotent/read-only calls, or add a request-id/idempotency contract plus recovery query semantics for timed-out mutations; for reusable clients, consider marking the connection tainted and rebuilding it after timeout instead of silently continuing.

---

## Follow-up — implementing Option 1

A team of subagents was tasked with tackling the adversarial finding:

- An `explore` agent independently classified every `XPCClient.send` and `ClientHealthCheck.ping` call site as mutating or idempotent.
- An `explore` agent mapped the existing test infrastructure and discovered `ContainerXPC` had no test target.
- An `oracle` consultation evaluated the three follow-up directions Codex suggested and recommended a Swift-idiomatic API shape.

### Audit correction

The earlier operator note in this document claimed:

> No mutating call site uses `responseTimeout` today.

**This was wrong.** Independent verification surfaced four live mutating-with-timeout call sites — three of them latent bugs that match the pattern Codex described:

| Caller | Route | `responseTimeout` (before this follow-up) | Server-side mutation |
|---|---|---|---|
| `ContainerClient.create` | `containerCreate` | 60s default via `xpcSend` wrapper | Allocates container state on disk |
| `NetworkClient.create` (APIService) | `networkCreate` | 60s default via `xpcSend` wrapper | Spawns a network plugin instance |
| `NetworkClient.delete` (APIService) | `networkDelete` | 60s default via `xpcSend` wrapper | Tears down a network plugin and removes state |
| `SandboxClient.create` | `sandboxCreateEndpoint` | 60s `timeout:` parameter | Creates an XPC endpoint owned by the sandbox process |

Under sufficient daemon load (or any slow-but-not-dead failure mode) any of these could silently double-commit on retry: the caller times out, surfaces a `.timeout` error, the user reruns the command, and the original operation later commits server-side.

### Decision

Implement **Option 1** ("restrict `responseTimeout` to idempotent operations") at the `XPCClient.send` API surface so future call sites cannot reach for the dangerous path by accident. Compile-time enforcement; no runtime flag.

### API after this follow-up

Two overloads on `XPCClient.send`. The old `responseTimeout:` parameter is retained as `@available(*, unavailable, ...)` so any reintroduction in a future patch fails to build with a teaching error.

```swift
// Mutating-safe. No timeout possible. Cancellation honored only before dispatch.
@discardableResult
public func send(_ message: XPCMessage) async throws -> XPCMessage

// Idempotent / read-only. Late replies dropped silently; reusable clients keep working.
@discardableResult
public func send(
    _ message: XPCMessage,
    timeoutForIdempotentRequest responseTimeout: Duration
) async throws -> XPCMessage

// Compile-time guard against the previous footgun spelling.
@available(*, unavailable, message: "...")
public func send(_ message: XPCMessage, responseTimeout: Duration?) async throws -> XPCMessage
```

Cancellation contract:

- `send(_:)` — `Task.checkCancellation()` runs before dispatch; after dispatch, cancellation is ignored and the call completes only when the daemon replies or the underlying connection is invalidated. Honoring cancellation after dispatch would re-introduce the same late-commit ambiguity as a timeout.
- `send(_:timeoutForIdempotentRequest:)` — keeps the existing race semantics (reply / timeout / cancellation, whichever wins), with late replies dropped.

### Call-site migrations

The four mutating-with-timeout call sites identified in the audit now use plain `send(_:)`:

- `ContainerClient.create` — `xpcSend(message:)` wrapper, no timeout
- `NetworkClient.create` (APIService) — same
- `NetworkClient.delete` (APIService) — same
- `SandboxClient.create` — `timeout:` parameter removed; the only caller (`ContainersService`) was already passing the default

Idempotent reads keep their bounded latency through the new `xpcSendIdempotent(message:timeout:)` helpers and through `ClientHealthCheck.ping(timeout:)` which now calls `send(_:timeoutForIdempotentRequest:)`. The seven `ClientHealthCheck.ping` call sites in `ContainerCommands` (Application, BuilderStart, BuildCommand, SystemStart/Stop/Status/Version) are unchanged at the call site.

### Tests

A new `ContainerXPCTests` target covers the contract:

- `idempotentTimeoutReturnsWithinBound` — verifies the timeout actually fires within bound when no reply arrives, and the error code is `.timeout` (not `.interrupted`)
- `reusableClientSurvivesIdempotentTimeout` — same `XPCClient` instance is used across a timed-out send and a successful follow-up send
- `lateReplyAfterIdempotentTimeoutIsIgnoredCleanly` — server replies after the client has timed out; the late reply must be dropped without crashing or corrupting subsequent sends
- `plainSendCompletesWhenServerReplies` — happy path for the mutating-safe overload
- `plainSendIgnoresCancellationAfterDispatch` — `Task.cancel()` after dispatch must NOT short-circuit the send; the task must wait for the reply
- `plainSendHonorsCancellationBeforeDispatch` — cancellation BEFORE the message is dispatched must surface `CancellationError`

The tests use an in-process `xpc_endpoint_create`-based listener so the contract can be exercised without a live mach service.

### What this PR still does not address

1. The reusable `ContainerClient` / `NetworkClient` instances make many mutating calls without any timeout (now correctly so, per the new contract). Wedged-daemon scenarios will hang those callers indefinitely; the user-visible workaround (`launchctl bootout`) is still the only escape today.
2. There is no idempotency-token or recovery-query protocol (Codex's third suggestion). The current solution prevents the unsafe combination at the API; it does not give callers a way to safely time out a mutating request and then ask the daemon "did it actually commit?".

Both are reasonable follow-ups but out of scope for closing the freeze regression.
