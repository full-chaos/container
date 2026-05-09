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

import ArgumentParser
import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationExtras
import Foundation
import TerminalProgress

extension Application {
    public struct NetworkCreate: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a new network")

        @Option(name: .customLong("label"), help: "Set metadata for a network")
        var labels: [String] = []

        @Flag(name: .customLong("internal"), help: "Restrict to host-only network")
        var hostOnly: Bool = false

        @Option(
            name: .customLong("subnet"), help: "Set subnet for a network",
            transform: {
                try CIDRv4($0)
            })
        var ipv4Subnet: CIDRv4? = nil

        @Option(
            name: .customLong("subnet-v6"), help: "Set the IPv6 prefix for a network",
            transform: {
                try CIDRv6($0)
            })
        var ipv6Subnet: CIDRv6? = nil

        @Option(name: .long, help: "Set the plugin to use to create this network.")
        var plugin: String = "container-network-vmnet"

        @Option(name: .long, help: "Set the variant of the network plugin to use.")
        var pluginVariant: String?

        @Option(
            name: .customLong("gateway"),
            help: "Set the IPv4 gateway address for the network. Defaults to the first usable host address in --subnet.",
            transform: {
                try IPv4Address($0)
            })
        var ipv4Gateway: IPv4Address? = nil

        @Option(
            name: .customLong("ip-range"),
            help: "Restrict dynamic IPv4 allocation to a sub-range of --subnet, expressed as CIDR.",
            transform: {
                try CIDRv4($0)
            })
        var ipv4Range: CIDRv4? = nil

        @Option(
            name: .customLong("aux-address"),
            help: "Reserve a static hostname-to-IPv4 mapping (HOSTNAME=IPV4). Repeatable.")
        var auxAddresses: [String] = []

        @Option(
            name: .customLong("driver-opt"),
            help: "Set a free-form network driver option (KEY=VALUE). Repeatable. Currently informational; the vmnet plugin does not interpret any keys.")
        var driverOpts: [String] = []

        @Flag(
            name: .customLong("attachable"),
            help: "Accepted for compose-spec parity. Currently a no-op on apple/container, which has no swarm concept.")
        var attachable: Bool = false

        @Flag(
            name: .customLong("ipv6"),
            help: "Enable IPv6 even when no --subnet-v6 is supplied. The runtime asks vmnet to auto-allocate an IPv6 prefix.")
        var enableIPv6: Bool = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Network name")
        var name: String

        public init() {}

        public func run() async throws {
            let parsedLabels = try ResourceLabels(Utility.parseKeyValuePairs(labels))
            let mode: NetworkMode = hostOnly ? .hostOnly : .nat

            let parsedAuxAddresses: [String: IPv4Address]?
            if auxAddresses.isEmpty {
                parsedAuxAddresses = nil
            } else {
                let raw = Utility.parseKeyValuePairs(auxAddresses)
                var mapped: [String: IPv4Address] = [:]
                mapped.reserveCapacity(raw.count)
                for (hostname, addressText) in raw {
                    mapped[hostname] = try IPv4Address(addressText)
                }
                parsedAuxAddresses = mapped
            }

            let parsedDriverOpts: [String: String]? = driverOpts.isEmpty ? nil : Utility.parseKeyValuePairs(driverOpts)

            // Compose-spec parity: report acceptance of attachable but make it explicit
            // that apple/container has no swarm-style attachment concept.
            if attachable {
                FileHandle.standardError.write(
                    Data("Note: --attachable is accepted for compose-spec parity but has no behavioral effect on apple/container.\n".utf8)
                )
            }

            // Either an explicit --subnet-v6 or an explicit --ipv6 enables IPv6 on the network.
            let resolvedEnableIPv6: Bool? = (enableIPv6 || ipv6Subnet != nil) ? true : nil

            let config = try NetworkConfiguration(
                id: self.name,
                mode: mode,
                ipv4Subnet: ipv4Subnet,
                ipv6Subnet: ipv6Subnet,
                ipv4Gateway: ipv4Gateway,
                ipv4Range: ipv4Range,
                auxAddresses: parsedAuxAddresses,
                driverOpts: parsedDriverOpts,
                attachable: attachable ? true : nil,
                enableIPv6: resolvedEnableIPv6,
                labels: parsedLabels,
                pluginInfo: NetworkPluginInfo(plugin: self.plugin, variant: self.pluginVariant)
            )
            let networkClient = NetworkClient()
            let network = try await networkClient.create(configuration: config)
            print(network.id)
        }
    }
}
