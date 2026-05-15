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

/// Declarative restart policy that the daemon stores on a created container.
///
/// The shape mirrors the in-flight upstream proposal in
/// [apple/container#1258](https://github.com/apple/container/pull/1258):
/// a bare `String`-backed enum with the conservative initial set
/// (`no`, `onFailure`, `always`). Bounded `on-failure:N` retries and
/// `unless-stopped` are intentionally deferred — they ship as separate
/// follow-ups once #1258 lands.
///
/// At present this is a data-shape only contract on the fork: the policy is
/// recorded in ``ContainerCreateOptions/restartPolicy`` but the daemon does
/// not yet observe container exits and re-launch per policy. Enforcement
/// will arrive via the upstream restart manager (#1258).
public enum RestartPolicy: String, Sendable, Codable, Equatable, CaseIterable {
    case no
    case onFailure
    case always
}
