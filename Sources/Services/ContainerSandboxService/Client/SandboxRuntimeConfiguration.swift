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
import Containerization
import ContainerizationError
import Foundation
import SystemPackage

public struct RuntimeConfiguration: Codable, Sendable {
    static let runtimeConfigurationFilename = "runtime-configuration.json"

    public let path: FilePath
    public let initialFilesystem: Filesystem
    public let kernel: Kernel
    public let containerConfiguration: ContainerConfiguration?
    public let containerRootFilesystem: Filesystem?
    public let options: ContainerCreateOptions?

    public init(
        path: FilePath,
        initialFilesystem: Filesystem,
        kernel: Kernel,
        containerConfiguration: ContainerConfiguration? = nil,
        containerRootFilesystem: Filesystem? = nil,
        options: ContainerCreateOptions? = nil
    ) {
        self.path = path
        self.initialFilesystem = initialFilesystem
        self.kernel = kernel
        self.containerConfiguration = containerConfiguration
        self.containerRootFilesystem = containerRootFilesystem
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case initialFilesystem
        case kernel
        case containerConfiguration
        case containerRootFilesystem
        case options
    }

    // FilePath's default Codable encoding exposes its internal _storage and
    // is not interchangeable with URL's plain-string form. To stay
    // wire-compatible with runtime-configuration.json files written before
    // the URL → FilePath migration, encode `path` as a plain string and
    // accept either the file:// URL form or a bare path on decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pathString = try container.decode(String.self, forKey: .path)
        if pathString.hasPrefix("file://"),
            let url = URL(string: pathString), url.isFileURL
        {
            self.path = FilePath(url.path(percentEncoded: false))
        } else {
            self.path = FilePath(pathString)
        }
        self.initialFilesystem = try container.decode(Filesystem.self, forKey: .initialFilesystem)
        self.kernel = try container.decode(Kernel.self, forKey: .kernel)
        self.containerConfiguration = try container.decodeIfPresent(ContainerConfiguration.self, forKey: .containerConfiguration)
        self.containerRootFilesystem = try container.decodeIfPresent(Filesystem.self, forKey: .containerRootFilesystem)
        self.options = try container.decodeIfPresent(ContainerCreateOptions.self, forKey: .options)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.path.string, forKey: .path)
        try container.encode(self.initialFilesystem, forKey: .initialFilesystem)
        try container.encode(self.kernel, forKey: .kernel)
        try container.encodeIfPresent(self.containerConfiguration, forKey: .containerConfiguration)
        try container.encodeIfPresent(self.containerRootFilesystem, forKey: .containerRootFilesystem)
        try container.encodeIfPresent(self.options, forKey: .options)
    }

    public var runtimeConfigurationPath: FilePath {
        self.path.appending(Self.runtimeConfigurationFilename)
    }

    public func writeRuntimeConfiguration() throws {
        // Ensure the parent directory exists
        try FileManager.default.createDirectory(atPath: self.path.string, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(self)
        try data.write(to: URL(fileURLWithPath: self.runtimeConfigurationPath.string))
    }

    public static func readRuntimeConfiguration(from runtimeConfigurationPath: FilePath) throws -> RuntimeConfiguration {
        let configurationPath = runtimeConfigurationPath.appending(RuntimeConfiguration.runtimeConfigurationFilename)
        guard FileManager.default.fileExists(atPath: configurationPath.string) else {
            throw ContainerizationError(
                .notFound,
                message: "runtime configuration file not found at path: \(configurationPath.string)"
            )
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: configurationPath.string))
        return try JSONDecoder().decode(RuntimeConfiguration.self, from: data)
    }
}
