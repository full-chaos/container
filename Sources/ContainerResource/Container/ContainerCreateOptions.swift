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

public struct ContainerCreateOptions: Codable, Sendable {
    /// Remove the container and wipe out its data on container stop
    public let autoRemove: Bool
    /// Override the rootFs with this one other than the image-cloned version
    public let rootFsOverride: Filesystem?
    /// Declarative restart policy recorded at creation time.
    ///
    /// Today this is data-shape only — the daemon stores the policy but does
    /// not observe exits and re-launch automatically. A restart-manager
    /// follow-up will honor this field at runtime.
    public let restartPolicy: RestartPolicy?

    public init(
        autoRemove: Bool,
        rootFsOverride: Filesystem? = nil,
        restartPolicy: RestartPolicy? = nil
    ) {
        self.autoRemove = autoRemove
        self.rootFsOverride = rootFsOverride
        self.restartPolicy = restartPolicy
    }

    public static let `default` = ContainerCreateOptions(autoRemove: false)

}
