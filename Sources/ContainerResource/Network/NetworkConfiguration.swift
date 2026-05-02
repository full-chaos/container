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

import ContainerizationError
import ContainerizationExtras
import Foundation

public struct NetworkPluginInfo: Codable, Sendable, Hashable {
    public let plugin: String
    public let variant: String?

    public init(plugin: String, variant: String? = nil) {
        self.plugin = plugin
        self.variant = variant
    }
}

/// Configuration parameters for network creation.
public struct NetworkConfiguration: Codable, Sendable, Identifiable {
    /// A unique identifier for the network
    public let id: String

    /// The network type
    public let mode: NetworkMode

    /// When the network was created.
    public let creationDate: Date

    /// The preferred CIDR address for the IPv4 subnet, if specified
    public let ipv4Subnet: CIDRv4?

    /// The preferred CIDR address for the IPv6 subnet, if specified
    public let ipv6Subnet: CIDRv6?

    /// Key-value labels for the network.
    /// Resource labels should not be mutated, except while building a network configurations.
    public let labels: ResourceLabels

    /// Details about the network plugin that manages this network.
    /// FIXME: This field only needs to be optional while we wait for the field
    /// to be proliferated to most users when they update container.
    public let pluginInfo: NetworkPluginInfo?

    /// The IPv4 gateway address for the network, if explicitly specified.
    /// When `nil`, the runtime derives the gateway from `ipv4Subnet` (typically
    /// the first usable host address). When set, the value must lie within
    /// `ipv4Subnet`.
    public let ipv4Gateway: IPv4Address?

    /// A sub-CIDR of `ipv4Subnet` from which the runtime should allocate
    /// dynamic IPv4 addresses. When `nil`, the entire usable subnet is
    /// available. When set, must be contained within `ipv4Subnet`.
    public let ipv4Range: CIDRv4?

    /// Static hostname-to-IPv4 reservations that must not be handed out by the
    /// dynamic allocator. Each address must lie within `ipv4Subnet`. Entries
    /// outside `ipv4Range` (when specified) are recorded but have no allocator
    /// effect because they are already outside the dynamic pool.
    public let auxAddresses: [String: IPv4Address]?

    /// Free-form network driver options. Persisted on the configuration and
    /// forwarded to the network plugin via repeated `--driver-opt KEY=VALUE`
    /// arguments. The vmnet plugin accepts no options today; future driver
    /// enhancements may interpret known keys without changing the wire format.
    public let driverOpts: [String: String]?

    /// Whether to allow ad-hoc container attachments to the network. Accepted
    /// for compose-spec parity but currently a no-op on apple/container,
    /// which does not have a multi-host swarm concept.
    public let attachable: Bool?

    /// Request IPv6 connectivity even when no explicit `ipv6Subnet` is
    /// configured. When `true` and `ipv6Subnet` is `nil`, the runtime asks
    /// vmnet to auto-allocate an IPv6 prefix at network start. The flag is
    /// implicitly `true` whenever `ipv6Subnet` is set.
    public let enableIPv6: Bool?

    /// Creates a network configuration
    public init(
        id: String,
        mode: NetworkMode,
        ipv4Subnet: CIDRv4? = nil,
        ipv6Subnet: CIDRv6? = nil,
        ipv4Gateway: IPv4Address? = nil,
        ipv4Range: CIDRv4? = nil,
        auxAddresses: [String: IPv4Address]? = nil,
        driverOpts: [String: String]? = nil,
        attachable: Bool? = nil,
        enableIPv6: Bool? = nil,
        labels: ResourceLabels = .init(),
        pluginInfo: NetworkPluginInfo?
    ) throws {
        self.id = id
        self.creationDate = Date()
        self.mode = mode
        self.ipv4Subnet = ipv4Subnet
        self.ipv6Subnet = ipv6Subnet
        self.ipv4Gateway = ipv4Gateway
        self.ipv4Range = ipv4Range
        self.auxAddresses = auxAddresses
        self.driverOpts = driverOpts
        self.attachable = attachable
        self.enableIPv6 = enableIPv6
        self.labels = labels
        self.pluginInfo = pluginInfo
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case creationDate
        case mode
        case ipv4Subnet
        case ipv6Subnet
        case ipv4Gateway
        case ipv4Range
        case auxAddresses
        case driverOpts
        case attachable
        case enableIPv6
        case labels
        case pluginInfo
        // TODO: retain for deserialization compatibility for now, remove later
        case subnet
    }

    /// Create a configuration from the supplied Decoder, initializing missing
    /// values where possible to reasonable defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate) ?? Date(timeIntervalSince1970: 0)
        mode = try container.decode(NetworkMode.self, forKey: .mode)
        let subnetText =
            try container.decodeIfPresent(String.self, forKey: .ipv4Subnet)
            ?? container.decodeIfPresent(String.self, forKey: .subnet)
        ipv4Subnet = try subnetText.map { try CIDRv4($0) }
        ipv6Subnet = try container.decodeIfPresent(String.self, forKey: .ipv6Subnet)
            .map { try CIDRv6($0) }
        ipv4Gateway = try container.decodeIfPresent(String.self, forKey: .ipv4Gateway)
            .map { try IPv4Address($0) }
        ipv4Range = try container.decodeIfPresent(String.self, forKey: .ipv4Range)
            .map { try CIDRv4($0) }
        if let rawAux = try container.decodeIfPresent([String: String].self, forKey: .auxAddresses) {
            var decoded: [String: IPv4Address] = [:]
            decoded.reserveCapacity(rawAux.count)
            for (hostname, addressText) in rawAux {
                decoded[hostname] = try IPv4Address(addressText)
            }
            auxAddresses = decoded
        } else {
            auxAddresses = nil
        }
        driverOpts = try container.decodeIfPresent([String: String].self, forKey: .driverOpts)
        attachable = try container.decodeIfPresent(Bool.self, forKey: .attachable)
        enableIPv6 = try container.decodeIfPresent(Bool.self, forKey: .enableIPv6)
        let decodedLabels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        labels = try .init(decodedLabels)
        pluginInfo = try container.decodeIfPresent(NetworkPluginInfo.self, forKey: .pluginInfo)
        try validate()
    }

    /// Encode the configuration to the supplied Encoder.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(creationDate, forKey: .creationDate)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(ipv4Subnet, forKey: .ipv4Subnet)
        try container.encodeIfPresent(ipv6Subnet, forKey: .ipv6Subnet)
        try container.encodeIfPresent(ipv4Gateway?.description, forKey: .ipv4Gateway)
        try container.encodeIfPresent(ipv4Range, forKey: .ipv4Range)
        if let auxAddresses {
            let encodable = auxAddresses.mapValues { $0.description }
            try container.encode(encodable, forKey: .auxAddresses)
        }
        try container.encodeIfPresent(driverOpts, forKey: .driverOpts)
        try container.encodeIfPresent(attachable, forKey: .attachable)
        try container.encodeIfPresent(enableIPv6, forKey: .enableIPv6)
        try container.encode(labels, forKey: .labels)
        try container.encodeIfPresent(pluginInfo, forKey: .pluginInfo)
    }

    private func validate() throws {
        guard NetworkResource.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "invalid network ID: \(id)")
        }
        if let ipv4Gateway, let ipv4Subnet {
            guard ipv4Subnet.contains(ipv4Gateway) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "gateway \(ipv4Gateway) is not within IPv4 subnet \(ipv4Subnet)"
                )
            }
        }
        if let ipv4Range, let ipv4Subnet {
            guard ipv4Subnet.contains(ipv4Range.lower) && ipv4Subnet.contains(ipv4Range.upper) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "ip-range \(ipv4Range) is not contained within IPv4 subnet \(ipv4Subnet)"
                )
            }
        }
        if let auxAddresses, let ipv4Subnet {
            for (hostname, address) in auxAddresses {
                guard ipv4Subnet.contains(address) else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "aux-address \(hostname)=\(address) is not within IPv4 subnet \(ipv4Subnet)"
                    )
                }
            }
        }
    }
}
