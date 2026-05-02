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

struct HealthStateMachineTest {
    private func makeHealthcheck(
        retries: Int = 3,
        startPeriod: TimeInterval? = nil
    ) throws -> Healthcheck {
        try Healthcheck(
            test: ["CMD-SHELL", "true"],
            retries: retries,
            startPeriod: startPeriod
        )
    }

    @Test func initialStateIsStartingWhenEnabled() throws {
        let sm = HealthStateMachine(configuration: try makeHealthcheck())
        #expect(sm.currentStatus == .starting)
    }

    @Test func initialStateIsNoneWhenDisabled() throws {
        let h = try Healthcheck(test: ["NONE"])
        let sm = HealthStateMachine(configuration: h)
        #expect(sm.currentStatus == .none)
    }

    @Test func successDuringGraceTransitionsImmediatelyToHealthy() throws {
        let h = try makeHealthcheck(startPeriod: 60)
        var sm = HealthStateMachine(configuration: h)
        sm.recordSuccess()
        #expect(sm.currentStatus == .healthy)
    }

    @Test func failuresDuringGraceDoNotCount() throws {
        let h = try makeHealthcheck(retries: 2, startPeriod: 60)
        var sm = HealthStateMachine(configuration: h)
        sm.recordFailure(containerAge: 5)
        sm.recordFailure(containerAge: 10)
        sm.recordFailure(containerAge: 15)
        #expect(sm.currentStatus == .starting)
        #expect(sm.consecutiveFailures == 0)
    }

    @Test func failuresAfterGraceCountTowardRetries() throws {
        let h = try makeHealthcheck(retries: 3, startPeriod: 30)
        var sm = HealthStateMachine(configuration: h)
        sm.recordFailure(containerAge: 60)
        #expect(sm.currentStatus == .starting)
        #expect(sm.consecutiveFailures == 1)
        sm.recordFailure(containerAge: 90)
        #expect(sm.currentStatus == .starting)
        #expect(sm.consecutiveFailures == 2)
        sm.recordFailure(containerAge: 120)
        #expect(sm.currentStatus == .unhealthy)
        #expect(sm.consecutiveFailures == 3)
    }

    @Test func successResetsFailureCounter() throws {
        let h = try makeHealthcheck(retries: 3)
        var sm = HealthStateMachine(configuration: h)
        sm.recordFailure(containerAge: 100)
        sm.recordFailure(containerAge: 130)
        #expect(sm.consecutiveFailures == 2)
        sm.recordSuccess()
        #expect(sm.currentStatus == .healthy)
        #expect(sm.consecutiveFailures == 0)
    }

    @Test func unhealthyRecoversToHealthyOnSuccess() throws {
        let h = try makeHealthcheck(retries: 1)
        var sm = HealthStateMachine(configuration: h)
        sm.recordFailure(containerAge: 100)
        #expect(sm.currentStatus == .unhealthy)
        sm.recordSuccess()
        #expect(sm.currentStatus == .healthy)
        #expect(sm.consecutiveFailures == 0)
    }

    @Test func disabledMachineIgnoresAllInputs() throws {
        let h = try Healthcheck(test: ["NONE"])
        var sm = HealthStateMachine(configuration: h)
        sm.recordSuccess()
        sm.recordFailure(containerAge: 100)
        #expect(sm.currentStatus == .none)
        #expect(sm.consecutiveFailures == 0)
    }

    @Test func retriesEqualsZeroFailsImmediatelyPostGrace() throws {
        let h = try makeHealthcheck(retries: 0)
        var sm = HealthStateMachine(configuration: h)
        sm.recordFailure(containerAge: 100)
        #expect(sm.currentStatus == .unhealthy)
    }
}
