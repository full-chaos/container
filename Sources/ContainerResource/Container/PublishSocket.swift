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
import SystemPackage

/// Represents a socket that should be published from container to host.
public struct PublishSocket: Sendable, Codable {
    /// The path to the socket in the container.
    public var containerPath: FilePath

    /// The path where the socket should appear on the host.
    public var hostPath: FilePath

    /// File permissions for the socket on the host.
    public var permissions: FilePermissions?

    public init(
        containerPath: FilePath,
        hostPath: FilePath,
        permissions: FilePermissions? = nil
    ) {
        self.containerPath = containerPath
        self.hostPath = hostPath
        self.permissions = permissions
    }

    private enum CodingKeys: String, CodingKey {
        case containerPath
        case hostPath
        case permissions
    }

    /// Encode paths as plain JSON strings.
    ///
    /// Previously these fields were `URL`s; `JSONEncoder` special-cases `URL`
    /// to encode as `absoluteString` (e.g. `"file:///var/run/docker.sock"`).
    /// `FilePath`'s synthesized Codable conformance uses a keyed container
    /// (`{"_storage": "..."}`), which would change the on-disk and XPC wire
    /// format. We override that here to keep the value a flat JSON string;
    /// the decoder accepts both the new clean form (`"/var/run/docker.sock"`)
    /// and the legacy `URL`-encoded form (`"file:///..."`).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(containerPath.string, forKey: .containerPath)
        try container.encode(hostPath.string, forKey: .hostPath)
        try container.encodeIfPresent(permissions, forKey: .permissions)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.containerPath = try Self.decodePath(from: container, forKey: .containerPath)
        self.hostPath = try Self.decodePath(from: container, forKey: .hostPath)
        self.permissions = try container.decodeIfPresent(FilePermissions.self, forKey: .permissions)
    }

    /// Decode a `FilePath` from either a plain path string or a legacy
    /// `URL.absoluteString` (e.g. `"file:///foo"`) for backward compatibility
    /// with container bundles persisted before the migration to `FilePath`.
    private static func decodePath(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> FilePath {
        let raw = try container.decode(String.self, forKey: key)
        if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL {
            return FilePath(url.path)
        }
        return FilePath(raw)
    }
}
