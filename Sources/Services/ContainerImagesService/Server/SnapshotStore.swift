//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerAPIClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging
import SystemPackage
import TerminalProgress

public actor SnapshotStore {
    private static let snapshotFileName = "snapshot"
    private static let snapshotInfoFileName = "snapshot-info"
    private static let ingestDirName = "ingest"

    /// Return the Unpacker to use for a given image.
    /// If the given platform for the image cannot be unpacked return `nil`.
    public typealias UnpackStrategy = @Sendable (Containerization.Image, Platform) async throws -> Unpacker?

    public static func defaultUnpackStrategy(initImage: String) -> UnpackStrategy {
        { image, platform in
            guard platform.os == "linux" else {
                return nil
            }
            var minBlockSize = 512.gib()
            if image.reference == initImage {
                minBlockSize = 512.mib()
            }
            return EXT4Unpacker(blockSizeInBytes: minBlockSize)
        }
    }

    let path: FilePath
    let fm = FileManager.default
    let ingestDir: FilePath
    let unpackStrategy: UnpackStrategy
    let log: Logger?

    public init(path: FilePath, unpackStrategy: @escaping UnpackStrategy, log: Logger?) throws {
        let root = path.appending("snapshots")
        self.path = root
        self.ingestDir = self.path.appending(Self.ingestDirName)
        self.unpackStrategy = unpackStrategy
        self.log = log
        try self.fm.createDirectory(atPath: root.string, withIntermediateDirectories: true, attributes: nil)
        try self.fm.createDirectory(atPath: self.ingestDir.string, withIntermediateDirectories: true, attributes: nil)
    }

    public func unpack(image: Containerization.Image, platform: Platform? = nil, progressUpdate: ProgressUpdateHandler?) async throws {
        var toUnpack: [Descriptor] = []
        if let platform {
            let desc = try await image.descriptor(for: platform)
            toUnpack = [desc]
        } else {
            toUnpack = try await image.unpackableDescriptors()
        }

        let taskManager = ProgressTaskCoordinator()
        var taskUpdateProgress: ProgressUpdateHandler?

        for desc in toUnpack {
            try Task.checkCancellation()
            let snapshotDir = self.snapshotDir(desc)
            guard !self.fm.fileExists(atPath: snapshotDir.string) else {
                // We have already unpacked this image + platform. Skip
                continue
            }
            guard let platform = desc.platform else {
                throw ContainerizationError(.internalError, message: "missing platform for descriptor \(desc.digest)")
            }
            guard let unpacker = try await self.unpackStrategy(image, platform) else {
                self.log?.warning("no unpacker configured, skipping unpack for \(image.reference) for platform \(platform.description)")
                continue
            }
            let currentSubTask = await taskManager.startTask()
            if let progressUpdate {
                let _taskUpdateProgress = ProgressTaskCoordinator.handler(for: currentSubTask, from: progressUpdate)
                await _taskUpdateProgress([
                    .setSubDescription("for platform \(platform.description)")
                ])
                taskUpdateProgress = _taskUpdateProgress
            }

            let tempDir = try self.tempUnpackDir()

            let tempSnapshotPath = URL(fileURLWithPath: tempDir.appending(Self.snapshotFileName).string, isDirectory: false)
            let infoPath = tempDir.appending(Self.snapshotInfoFileName)
            do {
                let progress = ContainerizationProgressAdapter.handler(from: taskUpdateProgress)
                let mount = try await unpacker.unpack(image, for: platform, at: tempSnapshotPath, progress: progress)
                let fs = Filesystem.block(
                    format: mount.type,
                    source: self.snapshotPath(desc).string,
                    destination: mount.destination,
                    options: mount.options
                )
                let snapshotInfo = try JSONEncoder().encode(fs)
                self.fm.createFile(atPath: infoPath.string, contents: snapshotInfo)
            } catch {
                try? self.fm.removeItem(atPath: tempDir.string)
                throw error
            }
            do {
                try fm.moveItem(atPath: tempDir.string, toPath: snapshotDir.string)
            } catch let err as NSError {
                guard err.code == NSFileWriteFileExistsError else {
                    throw err
                }
                try? self.fm.removeItem(atPath: tempDir.string)
            }
        }
        await taskManager.finish()
    }

    public func delete(for image: Containerization.Image, platform: Platform? = nil) async throws {
        var toDelete: [Descriptor] = []
        if let platform {
            let desc = try await image.descriptor(for: platform)
            toDelete.append(desc)
        } else {
            toDelete = try await image.unpackableDescriptors()
        }
        for desc in toDelete {
            let p = self.snapshotDir(desc)
            guard self.fm.fileExists(atPath: p.string) else {
                continue
            }
            try self.fm.removeItem(atPath: p.string)
        }
    }

    public func get(for image: Containerization.Image, platform: Platform) async throws -> Filesystem {
        let desc = try await image.descriptor(for: platform)
        let infoPath = snapshotInfoPath(desc)
        let fsPath = snapshotPath(desc)

        guard self.fm.fileExists(atPath: infoPath.string),
            self.fm.fileExists(atPath: fsPath.string)
        else {
            throw ContainerizationError(.notFound, message: "image snapshot for \(image.reference) with platform \(platform.description)")
        }
        let decoder = JSONDecoder()
        let data = try Data(contentsOf: URL(filePath: infoPath.string))
        let fs = try decoder.decode(Filesystem.self, from: data)
        return fs
    }

    public func clean(keepingSnapshotsFor images: [Containerization.Image] = []) async throws -> UInt64 {
        var toKeep: [String] = [Self.ingestDirName]
        for image in images {
            for manifest in try await image.index().manifests {
                guard let platform = manifest.platform else {
                    continue
                }
                let desc = try await image.descriptor(for: platform)
                toKeep.append(desc.digest.trimmingDigestPrefix)
            }
        }
        let all = try self.fm.contentsOfDirectory(atPath: self.path.string)
        let delete = Set(all).subtracting(Set(toKeep))
        var deletedBytes: UInt64 = 0
        for dir in delete {
            let unpackedPath = self.path.appending(dir)
            guard self.fm.fileExists(atPath: unpackedPath.string) else {
                continue
            }
            deletedBytes += (try? self.fm.directorySize(dir: unpackedPath)) ?? 0
            try self.fm.removeItem(atPath: unpackedPath.string)
        }
        return deletedBytes
    }

    private func snapshotDir(_ desc: Descriptor) -> FilePath {
        self.path.appending(desc.digest.trimmingDigestPrefix)
    }

    private func snapshotPath(_ desc: Descriptor) -> FilePath {
        self.snapshotDir(desc).appending(Self.snapshotFileName)
    }

    private func snapshotInfoPath(_ desc: Descriptor) -> FilePath {
        self.snapshotDir(desc).appending(Self.snapshotInfoFileName)
    }

    private func tempUnpackDir() throws -> FilePath {
        let uniqueDir = ingestDir.appending(UUID().uuidString)
        try self.fm.createDirectory(atPath: uniqueDir.string, withIntermediateDirectories: true, attributes: nil)
        return uniqueDir
    }

    /// Get the disk size for a specific snapshot descriptor
    public func getSnapshotSize(descriptor: Descriptor) throws -> UInt64 {
        let snapshotPath = self.snapshotDir(descriptor)
        guard self.fm.fileExists(atPath: snapshotPath.string) else {
            return 0
        }
        return try self.fm.directorySize(dir: snapshotPath)
    }
}

extension FileManager {
    fileprivate func directorySize(dir: FilePath) throws -> UInt64 {
        var size: UInt64 = 0
        let resourceKeys: [URLResourceKey] = [.totalFileAllocatedSizeKey]

        // URL boundary: required by URLEnumerator API; no FilePath equivalent
        let dirURL = URL(fileURLWithPath: dir.string, isDirectory: true)
        guard
            let enumerator = self.enumerator(
                at: dirURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            )
        else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                let fileSize = resourceValues.totalFileAllocatedSize
            {
                size += UInt64(fileSize)
            }
        }
        return size
    }
}

extension Containerization.Image {
    fileprivate func unpackableDescriptors() async throws -> [Descriptor] {
        let index = try await self.index()
        return index.manifests.filter { desc in
            guard desc.platform != nil else {
                return false
            }
            if let referenceType = desc.annotations?["vnd.docker.reference.type"], referenceType == "attestation-manifest" {
                return false
            }
            return true
        }
    }
}
