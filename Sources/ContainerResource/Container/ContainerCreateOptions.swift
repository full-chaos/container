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
    /// not observe exits and re-launch automatically. Enforcement is tracked
    /// by upstream [apple/container#1258](https://github.com/apple/container/pull/1258).
    ///
    /// Defaults to ``RestartPolicy/no``. Decoded with `decodeIfPresent` so
    /// older `options.json` blobs written before the field existed continue to
    /// load (forward-compatible additive change).
    public let restartPolicy: RestartPolicy

    public init(
        autoRemove: Bool,
        rootFsOverride: Filesystem? = nil,
        restartPolicy: RestartPolicy = .no
    ) {
        self.autoRemove = autoRemove
        self.rootFsOverride = rootFsOverride
        self.restartPolicy = restartPolicy
    }

    public static let `default` = ContainerCreateOptions(autoRemove: false)

    enum CodingKeys: String, CodingKey {
        case autoRemove
        case rootFsOverride
        case restartPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.autoRemove = try container.decode(Bool.self, forKey: .autoRemove)
        self.rootFsOverride = try container.decodeIfPresent(Filesystem.self, forKey: .rootFsOverride)
        self.restartPolicy = try container.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy) ?? .no
    }
}
