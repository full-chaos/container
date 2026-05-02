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

import ContainerizationError
import Foundation

/// Configuration for a periodic, container-level healthcheck.
///
/// The shape mirrors the Docker / compose-spec healthcheck schema so that
/// downstream tools (the canonical use case is a compose-spec orchestrator
/// implementing `depends_on.condition: service_healthy`) can populate this
/// type directly from a `docker-compose.yml` `healthcheck:` block.
///
/// Semantics applied by the daemon's healthcheck observer:
///
/// 1. When the observer starts and the healthcheck is enabled, the
///    container's ``ContainerSnapshot/health`` is set to
///    ``HealthStatus/starting``.
/// 2. While the wall-clock age of the container is within ``startPeriod``,
///    failed probes do not advance the consecutive failure counter.
///    Successful probes during the grace period transition the container
///    immediately to ``HealthStatus/healthy``.
/// 3. After the grace period elapses, ``retries`` consecutive failed probes
///    transition the container to ``HealthStatus/unhealthy``. A subsequent
///    successful probe resets the counter and transitions back to
///    ``HealthStatus/healthy`` without requiring a restart.
/// 4. A probe that does not return within ``timeout`` counts as a failed
///    probe.
/// 5. ``test`` of `["NONE"]` and ``disable`` set to `true` both bypass the
///    observer entirely; ``ContainerSnapshot/health`` remains `nil`.
public struct Healthcheck: Codable, Sendable, Equatable {
    /// The probe specification.
    ///
    /// Compatible shapes:
    /// - `["NONE"]` — disable any healthcheck inherited from the image.
    /// - `["CMD", "executable", "arg1", ...]` — run `executable` with the
    ///   supplied arguments directly inside the container. Exit code `0`
    ///   means healthy, any other exit code means unhealthy.
    /// - `["CMD-SHELL", "shell command string"]` — run the entire command
    ///   string through the container's default shell (`/bin/sh -c`).
    public let test: [String]

    /// Time between consecutive probes, in seconds. Defaults to 30 seconds.
    public let interval: TimeInterval

    /// Per-probe deadline, in seconds. A probe that does not return within
    /// this window counts as a failed probe. Defaults to 30 seconds.
    public let timeout: TimeInterval

    /// Number of consecutive failed probes that transition the container
    /// from ``HealthStatus/healthy`` (or ``HealthStatus/starting``) to
    /// ``HealthStatus/unhealthy``. Defaults to 3.
    public let retries: Int

    /// Optional grace window, in seconds, during which failed probes do not
    /// count toward ``retries``. The first successful probe during this
    /// window transitions the container immediately to
    /// ``HealthStatus/healthy``. When `nil`, no grace is applied.
    public let startPeriod: TimeInterval?

    /// Optional probe interval used while the container is still within
    /// ``startPeriod``. When `nil`, ``interval`` is used during the grace
    /// window as well.
    public let startInterval: TimeInterval?

    /// Bypass the observer entirely. Equivalent to ``test`` = `["NONE"]`.
    public let disable: Bool?

    /// Default probe interval applied when the configuration omits one.
    public static let defaultInterval: TimeInterval = 30
    /// Default per-probe deadline applied when the configuration omits one.
    public static let defaultTimeout: TimeInterval = 30
    /// Default consecutive-failure threshold applied when the configuration
    /// omits one.
    public static let defaultRetries: Int = 3

    public init(
        test: [String],
        interval: TimeInterval = Healthcheck.defaultInterval,
        timeout: TimeInterval = Healthcheck.defaultTimeout,
        retries: Int = Healthcheck.defaultRetries,
        startPeriod: TimeInterval? = nil,
        startInterval: TimeInterval? = nil,
        disable: Bool? = nil
    ) throws {
        self.test = test
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
        self.startPeriod = startPeriod
        self.startInterval = startInterval
        self.disable = disable
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case test
        case interval
        case timeout
        case retries
        case startPeriod
        case startInterval
        case disable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        test = try container.decode([String].self, forKey: .test)
        interval = try container.decodeIfPresent(TimeInterval.self, forKey: .interval) ?? Healthcheck.defaultInterval
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? Healthcheck.defaultTimeout
        retries = try container.decodeIfPresent(Int.self, forKey: .retries) ?? Healthcheck.defaultRetries
        startPeriod = try container.decodeIfPresent(TimeInterval.self, forKey: .startPeriod)
        startInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .startInterval)
        disable = try container.decodeIfPresent(Bool.self, forKey: .disable)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(test, forKey: .test)
        try container.encode(interval, forKey: .interval)
        try container.encode(timeout, forKey: .timeout)
        try container.encode(retries, forKey: .retries)
        try container.encodeIfPresent(startPeriod, forKey: .startPeriod)
        try container.encodeIfPresent(startInterval, forKey: .startInterval)
        try container.encodeIfPresent(disable, forKey: .disable)
    }

    /// Whether the healthcheck is effectively disabled (no observer should
    /// be started, ``ContainerSnapshot/health`` remains `nil`).
    public var isEffectivelyDisabled: Bool {
        if disable == true { return true }
        if test.count == 1 && test[0] == "NONE" { return true }
        return false
    }

    /// The probe interval that should be used at the supplied wall-clock age
    /// of the container. Returns ``startInterval`` while the container is
    /// still within ``startPeriod``, otherwise ``interval``.
    public func probeInterval(forContainerAge age: TimeInterval) -> TimeInterval {
        if let startPeriod, age < startPeriod, let startInterval {
            return startInterval
        }
        return interval
    }

    private func validate() throws {
        guard !test.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "healthcheck test must not be empty"
            )
        }
        if !isEffectivelyDisabled {
            switch test[0] {
            case "CMD", "CMD-SHELL":
                guard test.count >= 2 else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "healthcheck test '\(test[0])' requires at least one argument"
                    )
                }
            default:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "healthcheck test must start with 'NONE', 'CMD', or 'CMD-SHELL' (got '\(test[0])')"
                )
            }
        }
        guard interval > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "healthcheck interval must be positive (got \(interval))"
            )
        }
        guard timeout > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "healthcheck timeout must be positive (got \(timeout))"
            )
        }
        guard retries >= 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "healthcheck retries must be non-negative (got \(retries))"
            )
        }
        if let startPeriod, startPeriod < 0 {
            throw ContainerizationError(
                .invalidArgument,
                message: "healthcheck start_period must be non-negative (got \(startPeriod))"
            )
        }
        if let startInterval, startInterval <= 0 {
            throw ContainerizationError(
                .invalidArgument,
                message: "healthcheck start_interval must be positive (got \(startInterval))"
            )
        }
    }
}
