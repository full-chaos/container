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
import ContainerizationEXT4
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
            let capacityInBytes: UInt64
            if image.reference == initImage {
                capacityInBytes = 512.mib()
            } else {
                capacityInBytes = 512.gib()
            }
            return EXT4Unpacker(capacityInBytes: capacityInBytes, journal: .init(defaultMode: .ordered))
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
            deletedBytes += self.fm.allocatedSize(of: URL(fileURLWithPath: unpackedPath.string, isDirectory: true))
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
    public func getSnapshotSize(descriptor: Descriptor) -> UInt64 {
        let snapshotPath = self.snapshotDir(descriptor)
        guard self.fm.fileExists(atPath: snapshotPath.string) else {
            return 0
        }
        return self.fm.allocatedSize(of: URL(fileURLWithPath: snapshotPath.string, isDirectory: true))
    }

    /// Returns (trimmed digest, size) pairs for every unpackable snapshot owned by the image.
    public func getSnapshotSizes(for image: Containerization.Image) async throws -> [(digest: String, size: UInt64)] {
        var results: [(digest: String, size: UInt64)] = []
        for descriptor in try await image.unpackableDescriptors() {
            let size = self.getSnapshotSize(descriptor: descriptor)
            guard size > 0 else { continue }
            results.append((descriptor.digest.trimmingDigestPrefix, size))
        }
        return results
    }

    /// Total allocated bytes across all snapshot storage (including orphans).
    public func totalAllocatedSize() -> UInt64 {
        self.fm.allocatedSize(of: URL(fileURLWithPath: self.path.string, isDirectory: true))
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
