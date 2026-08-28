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

/// Pure state machine that maps a sequence of healthcheck probe outcomes to a
/// ``HealthStatus`` for a single container. This type is intentionally
/// dependency-free so the transition rules (Docker-compatible: grace window,
/// retries threshold, recovery without restart) can be exercised in isolation
/// by the unit-test layer.
public struct HealthStateMachine: Sendable {
    public let configuration: Healthcheck
    public private(set) var currentStatus: HealthStatus
    public private(set) var consecutiveFailures: Int

    public init(configuration: Healthcheck) {
        self.configuration = configuration
        self.consecutiveFailures = 0
        self.currentStatus = configuration.isEffectivelyDisabled ? .none : .starting
    }

    /// Record a probe that completed successfully (exit code zero). Resets the
    /// consecutive failure counter and transitions the status to ``.healthy``.
    /// No-op when the healthcheck is disabled.
    public mutating func recordSuccess() {
        guard !configuration.isEffectivelyDisabled else { return }
        consecutiveFailures = 0
        currentStatus = .healthy
    }

    /// Record a probe that did not complete successfully. Failures occurring
    /// while the container's age is still within ``Healthcheck/startPeriod``
    /// do not advance the consecutive failure counter (grace window).
    /// Otherwise the counter advances and the status transitions to
    /// ``.unhealthy`` once it reaches ``Healthcheck/retries``.
    public mutating func recordFailure(containerAge: TimeInterval) {
        guard !configuration.isEffectivelyDisabled else { return }
        if let startPeriod = configuration.startPeriod, containerAge < startPeriod {
            return
        }
        consecutiveFailures += 1
        if consecutiveFailures >= configuration.retries {
            currentStatus = .unhealthy
        }
    }
}
