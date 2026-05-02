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

import ContainerNetworkServiceClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

public actor NetworkService: Sendable {
    private let network: any Network
    private let log: Logger
    private var allocator: AttachmentAllocator
    private var macAddresses: [UInt32: MACAddress]

    /// Set up a network service for the specified network.
    public init(
        network: any Network,
        log: Logger
    ) async throws {
        let state = await network.state
        guard case .running(let configuration, let status) = state else {
            throw ContainerizationError(.invalidState, message: "invalid network state - network \(state.id) must be running")
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
        self.allocator = try AttachmentAllocator(lower: allocatorLower, size: allocatorSize)
        self.macAddresses = [:]
        self.network = network
        self.log = log

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
    public func state(_ message: XPCMessage) async throws -> XPCMessage {
        let reply = message.reply()
        let state = await network.state
        try reply.setState(state)
        return reply
    }

    @Sendable
    public func allocate(_ message: XPCMessage) async throws -> XPCMessage {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        let state = await network.state
        guard case .running(_, let status) = state else {
            throw ContainerizationError(.invalidState, message: "invalid network state - network \(state.id) must be running")
        }

        let hostname = try message.hostname()
        let macAddress =
            try message.string(key: NetworkKeys.macAddress.rawValue)
            .map { try MACAddress($0) }
            ?? MACAddress((UInt64.random(in: 0...UInt64.max) & 0x0cff_ffff_ffff) | 0xf200_0000_0000)
        let index = try await allocator.allocate(hostname: hostname)
        let ipv6Address = try status.ipv6Subnet
            .map { try CIDRv6(macAddress.ipv6Address(network: $0.lower), prefix: $0.prefix) }
        let ip = IPv4Address(index)
        let attachment = Attachment(
            network: state.id,
            hostname: hostname,
            ipv4Address: try CIDRv4(ip, prefix: status.ipv4Subnet.prefix),
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress
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
        let reply = message.reply()
        try reply.setAttachment(attachment)
        try network.withAdditionalData {
            if let additionalData = $0 {
                try reply.setAdditionalData(additionalData.underlying)
            }
        }
        macAddresses[index] = macAddress
        return reply
    }

    @Sendable
    public func deallocate(_ message: XPCMessage) async throws -> XPCMessage {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        let hostname = try message.hostname()
        if let index = try await allocator.deallocate(hostname: hostname) {
            macAddresses.removeValue(forKey: index)
        }
        log.info("released attachments", metadata: ["hostname": "\(hostname)"])
        return message.reply()
    }

    @Sendable
    public func lookup(_ message: XPCMessage) async throws -> XPCMessage {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        let state = await network.state
        guard case .running(_, let status) = state else {
            throw ContainerizationError(.invalidState, message: "invalid network state - network \(state.id) must be running")
        }

        let hostname = try message.hostname()
        let index = try await allocator.lookup(hostname: hostname)
        let reply = message.reply()
        guard let index else {
            return reply
        }
        guard let macAddress = macAddresses[index] else {
            return reply
        }
        let address = IPv4Address(index)
        let subnet = status.ipv4Subnet
        let ipv4Address = try CIDRv4(address, prefix: subnet.prefix)
        let ipv6Address = try status.ipv6Subnet
            .map { try CIDRv6(macAddress.ipv6Address(network: $0.lower), prefix: $0.prefix) }
        let attachment = Attachment(
            network: state.id,
            hostname: hostname,
            ipv4Address: ipv4Address,
            ipv4Gateway: status.ipv4Gateway,
            ipv6Address: ipv6Address,
            macAddress: macAddress
        )
        log.debug(
            "lookup attachment",
            metadata: [
                "hostname": "\(hostname)",
                "address": "\(address)",
            ])
        try reply.setAttachment(attachment)
        return reply
    }

    @Sendable
    public func disableAllocator(_ message: XPCMessage) async throws -> XPCMessage {
        log.debug("enter", metadata: ["func": "\(#function)"])
        defer { log.debug("exit", metadata: ["func": "\(#function)"]) }

        let success = await allocator.disableAllocator()
        log.info("attempted allocator disable", metadata: ["success": "\(success)"])
        let reply = message.reply()
        reply.setAllocatorDisabled(success)
        return reply
    }
}

extension XPCMessage {
    fileprivate func setAdditionalData(_ additionalData: xpc_object_t) throws {
        xpc_dictionary_set_value(self.underlying, NetworkKeys.additionalData.rawValue, additionalData)
    }

    fileprivate func setAllocatorDisabled(_ allocatorDisabled: Bool) {
        self.set(key: NetworkKeys.allocatorDisabled.rawValue, value: allocatorDisabled)
    }

    fileprivate func setAttachment(_ attachment: Attachment) throws {
        let data = try JSONEncoder().encode(attachment)
        self.set(key: NetworkKeys.attachment.rawValue, value: data)
    }

    fileprivate func setState(_ state: NetworkState) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: NetworkKeys.state.rawValue, value: data)
    }
}
