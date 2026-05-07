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
import ContainerSandboxServiceClient
import Foundation
import Logging

/// The outcome of a single healthcheck probe attempt.
public enum HealthProbeResult: Sendable, Equatable {
    case success
    case failure(exitCode: Int32?)
    case timedOut
}

/// Abstracts the execution of a single probe so that the observer logic can
/// be unit-tested without a running sandbox.
public protocol HealthProber: Sendable {
    /// Run a single probe inside the addressed container and return the
    /// outcome. The implementation is responsible for enforcing the supplied
    /// `timeout`; callers expect this method to return promptly.
    func runProbe(
        containerID: String,
        test: [String],
        timeout: TimeInterval
    ) async -> HealthProbeResult
}

/// Production ``HealthProber`` that drives an existing ``SandboxClient`` to
/// spawn a fresh process per probe. Stdio is intentionally not forwarded so
/// the probe leaves no log output behind; the exit code (or absence thereof
/// on timeout) is the only signal consumed.
public struct SandboxClientHealthProber: HealthProber {
    private let sandboxClient: SandboxClient
    private let log: Logger?
    private static let probeIDPrefix = "__container_healthcheck_"

    public init(sandboxClient: SandboxClient, log: Logger? = nil) {
        self.sandboxClient = sandboxClient
        self.log = log
    }

    public func runProbe(
        containerID: String,
        test: [String],
        timeout: TimeInterval
    ) async -> HealthProbeResult {
        guard let processConfig = Self.makeProcessConfiguration(test: test) else {
            return .failure(exitCode: nil)
        }
        let probeID = Self.probeIDPrefix + UUID().uuidString

        do {
            try await sandboxClient.createProcess(probeID, config: processConfig, stdio: [nil, nil, nil])
            try await sandboxClient.startProcess(probeID)
        } catch {
            log?.warning(
                "healthcheck probe failed to start",
                metadata: [
                    "id": "\(containerID)",
                    "probe": "\(probeID)",
                    "error": "\(error)",
                ])
            return .failure(exitCode: nil)
        }

        let outcome = await withTaskGroup(of: HealthProbeResult.self) { group in
            group.addTask { [sandboxClient] in
                do {
                    let status = try await sandboxClient.wait(probeID)
                    return status.exitCode == 0
                        ? .success
                        : .failure(exitCode: status.exitCode)
                } catch is CancellationError {
                    return .timedOut
                } catch {
                    return .failure(exitCode: nil)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }

            let first = await group.next() ?? .failure(exitCode: nil)
            // Unblock any still-running wait() by killing the synthetic probe.
            // Done before draining the group so the wait task can return.
            if first == .timedOut {
                try? await sandboxClient.kill(probeID, signal: 9)
            }
            group.cancelAll()
            for await _ in group {}
            return first
        }
        return outcome
    }

    private static func makeProcessConfiguration(test: [String]) -> ProcessConfiguration? {
        guard let kind = test.first else { return nil }
        switch kind {
        case "CMD":
            guard test.count >= 2 else { return nil }
            return ProcessConfiguration(
                executable: test[1],
                arguments: Array(test.dropFirst(2)),
                environment: []
            )
        case "CMD-SHELL":
            guard test.count >= 2 else { return nil }
            return ProcessConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", test[1]],
                environment: []
            )
        default:
            return nil
        }
    }
}
