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

/// A discrete container lifecycle event recorded by the daemon and returned
/// to clients via ``ContainerClient/events()``.
///
/// Events are recorded in-process by `ContainersService` at the moment a
/// container transitions through `create` / `start` / `stop` / `die` /
/// `destroy`. The daemon retains a bounded ring buffer of the most recent
/// events; callers requesting events after the buffer rolls over will miss
/// the dropped frames. There is no persistence across daemon restarts.
public struct ContainerEvent: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable, Equatable {
        case create
        case start
        case stop
        case die
        case destroy
    }

    public let containerId: String
    public let action: Action
    public let timestamp: Date

    public init(containerId: String, action: Action, timestamp: Date = Date()) {
        self.containerId = containerId
        self.action = action
        self.timestamp = timestamp
    }
}
