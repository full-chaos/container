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
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Logging

public actor DefaultNetworkService: NetworkService {
    private let network: any Network
    private let log: Logger
    private var allocator: AttachmentAllocator
    private var macAddresses: [UInt32: MACAddress]
    private var allocationsBySession: [XPCServerSession: [(hostname: String, index: UInt32)]]

    /// Set up a network service for the specified network.
    public init(
        network: any Network,
        configuration: NetworkConfiguration,
        log: Logger
    ) async throws {
        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        let subnet = status.ipv4Subnet

        // Determine the allocator range. By default skip the network address,
        // gateway, and broadcast (`subnet.lower + 2 ... subnet.upper - 1`). When
        // an explicit `ipv4Range` was configured, use exactly that span as the
        // allocator's pool — the user has taken responsibility for excluding
        // the gateway and any aux reservations.
        let allocatorLower: UInt32
        let allocatorSize: Int
        if let ipv4Range = configuration.ipv4Range {
            allocatorLower = ipv4Range.lower.value
            allocatorSize = Int(ipv4Range.upper.value - ipv4Range.lower.value + 1)
        } else {
            allocatorLower = subnet.lower.value + 2
            allocatorSize = Int(subnet.upper.value - subnet.lower.value - 3)
        }
        self.network = network
        self.log = log
        self.allocator = try AttachmentAllocator(lower: allocatorLower, size: allocatorSize)
        self.macAddresses = [:]
        self.allocationsBySession = [:]

        // If the configured IPv4 gateway differs from the default (`subnet.lower + 1`)
        // and falls within the dynamic allocator's pool, reserve it so the runtime
        // never hands the gateway out to a container.
        if let configuredGateway = configuration.ipv4Gateway, configuredGateway.value != subnet.lower.value + 1 {
            if configuredGateway.value >= allocatorLower
                && configuredGateway.value < allocatorLower + UInt32(allocatorSize)
            {
                do {
                    try await self.allocator.reserveHostname(
                        hostname: "__gateway__",
                        address: configuredGateway.value
                    )
                } catch {
                    log.warning(
                        "failed to pre-reserve configured gateway address",
                        metadata: [
                            "address": "\(configuredGateway)",
                            "error": "\(error)",
                        ])
                }
            }
        }

        // Pre-reserve aux addresses that fall within the allocator's range so the
        // dynamic allocator never hands them out. Out-of-range aux addresses are
        // recorded in logs only — they are already outside the dynamic pool.
        if let auxAddresses = configuration.auxAddresses {
            for (hostname, address) in auxAddresses {
                let value = address.value
                guard
                    value >= allocatorLower
                        && value < allocatorLower + UInt32(allocatorSize)
                else {
                    log.info(
                        "aux address outside dynamic allocation range; recorded for reference only",
                        metadata: [
                            "hostname": "\(hostname)",
                            "address": "\(address)",
                        ])
                    continue
                }
                do {
                    try await self.allocator.reserveHostname(hostname: hostname, address: value)
                    log.info(
                        "pre-reserved aux address",
                        metadata: [
                            "hostname": "\(hostname)",
                            "address": "\(address)",
                        ])
                } catch {
                    log.warning(
                        "failed to pre-reserve aux address",
                        metadata: [
                            "hostname": "\(hostname)",
                            "address": "\(address)",
                            "error": "\(error)",
                        ])
                }
            }
        }
    }

    @Sendable
    public func status() async throws -> NetworkStatus {
        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) is not running")
        }
        return status
    }

    @Sendable
    public func allocate(
        hostname: String,
        macAddress: MACAddress?,
        session: XPCServerSession
    ) async throws -> (attachment: Attachment, additionalData: XPCMessage?) {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        let macAddress = macAddress ?? MACAddress((UInt64.random(in: 0...UInt64.max) & 0x0cff_ffff_ffff) | 0xf200_0000_0000)
        let index = try await allocator.allocate(hostname: hostname)
        let ipv6Address = try status.ipv6Subnet
            .map { try CIDRv6(macAddress.ipv6Address(network: $0.lower), prefix: $0.prefix) }
        let ip = IPv4Address(index)
        let attachment = Attachment(
            network: network.id,
            hostname: hostname,
            ipv4Address: try CIDRv4(ip, prefix: status.ipv4Subnet.prefix),
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress,
            variant: network.variant
        )
        log.info(
            "allocated attachment",
            metadata: [
                "hostname": "\(hostname)",
                "ipv4Address": "\(attachment.ipv4Address)",
                "ipv4Gateway": "\(attachment.ipv4Gateway)",
                "ipv6Address": "\(attachment.ipv6Address?.description ?? "unavailable")",
                "macAddress": "\(attachment.macAddress?.description ?? "unspecified")",
            ])

        var additionalData: XPCMessage?
        try network.withAdditionalData {
            additionalData = $0
        }
        macAddresses[index] = macAddress

        let isNewSession = allocationsBySession[session] == nil
        allocationsBySession[session, default: []].append((hostname: hostname, index: index))
        if isNewSession {
            await session.onDisconnect { [weak self] in
                await self?.releaseSession(session)
            }
        }

        return (attachment: attachment, additionalData: additionalData)
    }

    private func releaseSession(_ session: XPCServerSession) async {
        guard let allocations = allocationsBySession.removeValue(forKey: session) else {
            return
        }
        for allocation in allocations {
            _ = try? await allocator.deallocate(hostname: allocation.hostname)
            macAddresses.removeValue(forKey: allocation.index)
        }
        log.info("released session", metadata: ["allocations": "\(allocations.count)"])
    }

    @Sendable
    public func lookup(hostname: String) async throws -> Attachment? {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let status = await network.status else {
            throw ContainerizationError(.invalidState, message: "network \(network.id) must be running")
        }

        // Invariant: hostname -> index if and only if index -> MAC address
        let index = try await allocator.lookup(hostname: hostname)
        guard let index else {
            return nil
        }
        guard let macAddress = macAddresses[index] else {
            return nil
        }

        let address = IPv4Address(index)
        let subnet = status.ipv4Subnet
        let ipv4Address = try CIDRv4(address, prefix: subnet.prefix)
        let ipv6Address = try status.ipv6Subnet
            .map { try CIDRv6(macAddress.ipv6Address(network: $0.lower), prefix: $0.prefix) }
        let attachment = Attachment(
            network: network.id,
            hostname: hostname,
            ipv4Address: ipv4Address,
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress,
            variant: network.variant
        )
        log.debug(
            "lookup attachment",
            metadata: [
                "hostname": "\(hostname)",
                "address": "\(address)",
            ])

        return attachment
    }
}
