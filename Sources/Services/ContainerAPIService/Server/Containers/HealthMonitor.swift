//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerResource
import Foundation
import Logging

/// Per-container healthcheck observer manager. Mirrors the lifecycle pattern
/// of ``ExitMonitor``: callers register a container at the moment it reaches
/// ``RuntimeStatus/running`` and unregister when it transitions away from
/// running. The actor owns the per-container observer ``Task`` and is the
/// single point that may cancel them.
///
/// Updates flow back to the caller through the supplied ``onUpdate`` callback
/// together with the generation token that was passed to ``register``. The
/// receiver is expected to drop updates whose generation no longer matches
/// the live container instance (see CHAOS-1381 design notes).
public actor HealthMonitor {
    /// Callback signature: `(containerID, generation, status)`.
    public typealias HealthUpdateCallback = @Sendable (String, UInt64, HealthStatus) async -> Void

    private var tasks: [String: Task<Void, Never>] = [:]
    private let log: Logger?

    public init(log: Logger? = nil) {
        self.log = log
    }

    /// Start observing the addressed container. Cancels any prior observer
    /// for the same id. When ``Healthcheck/isEffectivelyDisabled`` is `true`
    /// the callback is invoked once with ``HealthStatus/none`` and no probe
    /// loop is started.
    public func register(
        id: String,
        generation: UInt64,
        startedAt: Date,
        healthcheck: Healthcheck,
        prober: any HealthProber,
        onUpdate: @escaping HealthUpdateCallback
    ) async {
        await cancelExistingTask(id: id)

        if healthcheck.isEffectivelyDisabled {
            await onUpdate(id, generation, .none)
            return
        }

        await onUpdate(id, generation, .starting)

        let log = self.log
        let task = Task { [prober] in
            var stateMachine = HealthStateMachine(configuration: healthcheck)
            var lastReportedStatus = stateMachine.currentStatus

            while !Task.isCancelled {
                let now = Date()
                let age = now.timeIntervalSince(startedAt)
                let interval = healthcheck.probeInterval(forContainerAge: age)

                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
                } catch {
                    return
                }

                let probeResult = await prober.runProbe(
                    containerID: id,
                    test: healthcheck.test,
                    timeout: healthcheck.timeout
                )

                let probeAge = Date().timeIntervalSince(startedAt)
                switch probeResult {
                case .success:
                    stateMachine.recordSuccess()
                case .failure, .timedOut:
                    stateMachine.recordFailure(containerAge: probeAge)
                }

                if stateMachine.currentStatus != lastReportedStatus {
                    lastReportedStatus = stateMachine.currentStatus
                    log?.info(
                        "health status transition",
                        metadata: [
                            "id": "\(id)",
                            "status": "\(stateMachine.currentStatus)",
                            "result": "\(probeResult)",
                        ])
                    await onUpdate(id, generation, stateMachine.currentStatus)
                }
            }
        }
        tasks[id] = task
    }

    /// Stop observing the addressed container if a task is registered. Idempotent.
    public func unregister(id: String) async {
        await cancelExistingTask(id: id)
    }

    /// Cancel every registered observer. Used during daemon shutdown.
    public func unregisterAll() async {
        for id in tasks.keys {
            tasks[id]?.cancel()
        }
        tasks.removeAll()
    }

    private func cancelExistingTask(id: String) async {
        if let existing = tasks.removeValue(forKey: id) {
            existing.cancel()
        }
    }
}
