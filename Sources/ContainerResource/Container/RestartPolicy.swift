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

import Foundation

/// Declarative restart policy that the daemon stores on a created container.
///
/// At present this is a data-shape only contract: the policy is recorded in
/// ``ContainerCreateOptions/restartPolicy`` and surfaced back via the
/// container snapshot, but the daemon does not yet observe container exits
/// and re-launch per policy. Wiring an actual restart manager is a follow-up.
public struct RestartPolicy: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, Equatable {
        case no
        case always
        case onFailure = "on-failure"
        case unlessStopped = "unless-stopped"
    }

    public let mode: Mode
    /// Maximum number of restart attempts when ``mode`` is ``Mode/onFailure``.
    /// Ignored for other modes. `0` means "unbounded retries".
    public let maxRetries: Int

    public static let none = RestartPolicy(mode: .no, maxRetries: 0)

    public init(mode: Mode, maxRetries: Int = 0) {
        self.mode = mode
        self.maxRetries = maxRetries
    }
}
