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

import Containerization
import ContainerizationError
import Foundation
import SystemPackage

public struct Bundle: Sendable {
    private static let initfsFilename = "initfs.ext4"
    private static let kernelFilename = "kernel.json"
    private static let kernelBinaryFilename = "kernel.bin"
    private static let containerRootFsBlockFilename = "rootfs.ext4"
    private static let containerRootFsFilename = "rootfs.json"

    static let containerConfigFilename = "config.json"

    /// The path to the bundle.
    public let path: FilePath

    public init(path: FilePath) {
        self.path = path
    }

    public var bootlog: FilePath {
        self.path.appending("vminitd.log")
    }

    public var containerRootfsBlock: FilePath {
        self.path.appending(Self.containerRootFsBlockFilename)
    }

    private var containerRootfsConfig: FilePath {
        self.path.appending(Self.containerRootFsFilename)
    }

    public var containerRootfs: Filesystem {
        get throws {
            // Foundation's `Data(contentsOf:)` only accepts `URL`, so bridge here.
            let data = try Data(contentsOf: URL(filePath: containerRootfsConfig.string))
            let fs = try JSONDecoder().decode(Filesystem.self, from: data)
            return fs
        }
    }

    /// Return the initial filesystem for a sandbox.
    public var initialFilesystem: Filesystem {
        .block(
            format: "ext4",
            source: self.path.appending(Self.initfsFilename).string,
            destination: "/",
            options: ["ro"]
        )
    }

    public var kernel: Kernel {
        get throws {
            try load(path: self.path.appending(Self.kernelFilename))
        }
    }

    public var configuration: ContainerConfiguration {
        get throws {
            try load(path: self.path.appending(Self.containerConfigFilename))
        }
    }
}

extension Bundle {
    public static func create(
        path: FilePath,
        initialFilesystem: Filesystem,
        kernel: Kernel,
        containerConfiguration: ContainerConfiguration? = nil,
        containerRootFilesystem: Filesystem? = nil,
        options: ContainerCreateOptions? = nil
    ) throws -> Bundle {
        try FileManager.default.createDirectory(atPath: path.string, withIntermediateDirectories: true)
        let kbin = path.appending(Self.kernelBinaryFilename)
        // `Kernel.path` is `URL` (Containerization API), so bridge across the FilePath/URL boundary.
        try FileManager.default.copyItem(at: kernel.path, to: URL(filePath: kbin.string))
        var k = kernel
        k.path = URL(filePath: kbin.string)
        try write(path.appending(Self.kernelFilename), value: k)

        switch initialFilesystem.type {
        case .block(let fmt, _, _):
            guard fmt == "ext4" else {
                fatalError("ext4 is the only supported format for initial filesystem")
            }
            // when saving the Initial Filesystem to the bundle
            // discard any filesystem information and just persist
            // the block into the Bundle.
            _ = try initialFilesystem.clone(to: path.appending(Self.initfsFilename).string)
        default:
            fatalError("invalid filesystem type for initial filesystem")
        }
        let bundle = Bundle(path: path)
        if let containerConfiguration {
            try bundle.write(filename: Self.containerConfigFilename, value: containerConfiguration)
        }

        if let rootFsOverride = options?.rootFsOverride {
            try bundle.setContainerRootFs(fs: rootFsOverride)
        } else if let containerRootFilesystem {
            let readonly = containerConfiguration?.readOnly ?? false
            try bundle.cloneContainerRootFs(cloning: containerRootFilesystem, readonly: readonly)
        }

        if let options {
            try bundle.write(filename: "options.json", value: options)
        }
        return bundle
    }
}

extension Bundle {
    /// Set the value of the configuration for the Bundle.
    public func set(configuration: ContainerConfiguration) throws {
        try write(filename: Self.containerConfigFilename, value: configuration)
    }

    /// Return the full filepath for a named resource in the Bundle.
    public func filePath(for name: String) -> FilePath {
        path.appending(name)
    }

    public func setContainerRootFs(fs: Filesystem) throws {
        let fsData = try JSONEncoder().encode(fs)
        // Foundation's `Data.write(to:)` only accepts `URL`, so bridge here.
        try fsData.write(to: URL(filePath: self.containerRootfsConfig.string))
    }

    public func cloneContainerRootFs(cloning fs: Filesystem, readonly: Bool = false) throws {
        var mutableFs = fs
        if readonly && !mutableFs.options.contains("ro") {
            mutableFs.options.append("ro")
        }
        let cloned = try mutableFs.clone(to: self.containerRootfsBlock.string)
        try setContainerRootFs(fs: cloned)
    }

    /// Delete the bundle and all of the resources contained inside.
    public func delete() throws {
        try FileManager.default.removeItem(atPath: self.path.string)
    }

    public func write(filename: String, value: Encodable) throws {
        try Self.write(self.path.appending(filename), value: value)
    }

    private static func write(_ path: FilePath, value: Encodable) throws {
        let data = try JSONEncoder().encode(value)
        // Foundation's `Data.write(to:)` only accepts `URL`, so bridge here.
        try data.write(to: URL(filePath: path.string))
    }

    public func load<T>(filename: String) throws -> T where T: Decodable {
        try load(path: self.path.appending(filename))
    }

    private func load<T>(path: FilePath) throws -> T where T: Decodable {
        // Foundation's `Data(contentsOf:)` only accepts `URL`, so bridge here.
        let data = try Data(contentsOf: URL(filePath: path.string))
        return try JSONDecoder().decode(T.self, from: data)
    }
}
