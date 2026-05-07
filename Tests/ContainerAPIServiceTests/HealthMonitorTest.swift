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
import Testing

@testable import ContainerAPIService

/// Mock prober that returns scripted results in order. Each call consumes one
/// entry; once exhausted it parks indefinitely so the test stays in a known
/// state when the observer is cancelled mid-loop.
private actor ScriptedProber: HealthProber {
    private var script: [HealthProbeResult]
    private var calls: [(containerID: String, test: [String], timeout: TimeInterval)] = []

    init(_ script: [HealthProbeResult]) {
        self.script = script
    }

    func runProbe(
        containerID: String,
        test: [String],
        timeout: TimeInterval
    ) async -> HealthProbeResult {
        calls.append((containerID, test, timeout))
        if script.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return .failure(exitCode: nil)
        }
        return script.removeFirst()
    }

    func recordedCalls() -> [(containerID: String, test: [String], timeout: TimeInterval)] {
        calls
    }
}

/// Drains a sequence of expected status updates emitted by the monitor.
private actor StatusRecorder {
    private var updates: [(id: String, generation: UInt64, status: HealthStatus)] = []
    private var continuations: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(id: String, generation: UInt64, status: HealthStatus) {
        updates.append((id, generation, status))
        // Wake any waiters whose threshold has been reached.
        continuations = continuations.filter { (threshold, cont) in
            if updates.count >= threshold {
                cont.resume()
                return false
            }
            return true
        }
    }

    func waitForUpdates(count: Int) async {
        if updates.count >= count { return }
        await withCheckedContinuation { cont in
            continuations.append((count, cont))
        }
    }

    func snapshot() -> [(id: String, generation: UInt64, status: HealthStatus)] {
        updates
    }
}

struct HealthMonitorTest {
    private func makeQuickHealthcheck(retries: Int = 1) throws -> Healthcheck {
        try Healthcheck(
            test: ["CMD-SHELL", "true"],
            interval: 0.005,
            timeout: 1,
            retries: retries
        )
    }

    @Test func disabledHealthcheckEmitsSingleNoneUpdate() async throws {
        let monitor = HealthMonitor()
        let prober = ScriptedProber([])
        let recorder = StatusRecorder()

        let h = try Healthcheck(test: ["NONE"])
        await monitor.register(
            id: "c1",
            generation: 1,
            startedAt: Date(),
            healthcheck: h,
            prober: prober
        ) { id, gen, status in
            await recorder.record(id: id, generation: gen, status: status)
        }
        await recorder.waitForUpdates(count: 1)
        let updates = await recorder.snapshot()
        #expect(updates.count == 1)
        #expect(updates[0].id == "c1")
        #expect(updates[0].generation == 1)
        #expect(updates[0].status == .none)
        await monitor.unregisterAll()
    }

    @Test func enabledHealthcheckEmitsStartingThenHealthy() async throws {
        let monitor = HealthMonitor()
        let prober = ScriptedProber([.success])
        let recorder = StatusRecorder()

        let h = try makeQuickHealthcheck()
        await monitor.register(
            id: "c1",
            generation: 7,
            startedAt: Date(),
            healthcheck: h,
            prober: prober
        ) { id, gen, status in
            await recorder.record(id: id, generation: gen, status: status)
        }
        await recorder.waitForUpdates(count: 2)
        let updates = await recorder.snapshot()
        #expect(updates.count >= 2)
        #expect(updates[0].status == .starting)
        #expect(updates[1].status == .healthy)
        #expect(updates.allSatisfy { $0.id == "c1" && $0.generation == 7 })
        await monitor.unregisterAll()
    }

    @Test func consecutiveFailuresEventuallyTransitionToUnhealthy() async throws {
        let monitor = HealthMonitor()
        let prober = ScriptedProber([
            .failure(exitCode: 1),
            .failure(exitCode: 1),
            .failure(exitCode: 1),
        ])
        let recorder = StatusRecorder()

        let h = try makeQuickHealthcheck(retries: 3)
        await monitor.register(
            id: "c1",
            generation: 1,
            startedAt: Date(),
            healthcheck: h,
            prober: prober
        ) { id, gen, status in
            await recorder.record(id: id, generation: gen, status: status)
        }
        await recorder.waitForUpdates(count: 2)
        let updates = await recorder.snapshot()
        let unhealthyUpdates = updates.filter { $0.status == .unhealthy }
        #expect(!unhealthyUpdates.isEmpty)
        await monitor.unregisterAll()
    }

    @Test func unregisterCancelsObserverLoop() async throws {
        let monitor = HealthMonitor()
        let prober = ScriptedProber([.success, .success, .success])
        let recorder = StatusRecorder()

        let h = try makeQuickHealthcheck()
        await monitor.register(
            id: "c1",
            generation: 1,
            startedAt: Date(),
            healthcheck: h,
            prober: prober
        ) { id, gen, status in
            await recorder.record(id: id, generation: gen, status: status)
        }
        // Allow at least one probe to land before cancelling.
        await recorder.waitForUpdates(count: 2)
        await monitor.unregister(id: "c1")

        // Sleep briefly to let any in-flight probes finish, then capture.
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = await recorder.snapshot().count

        // Verify that no significant additional updates accrue beyond what
        // arrived during the brief settle window after cancellation.
        try await Task.sleep(nanoseconds: 100_000_000)
        let later = await recorder.snapshot().count
        #expect(later <= after + 1)
    }
}
