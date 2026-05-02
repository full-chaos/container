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

import ArgumentParser
import ContainerLog
import ContainerNetworkService
import ContainerNetworkServiceClient
import ContainerPlugin
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationExtras
import Foundation
import Logging

enum Variant: String, ExpressibleByArgument {
    case reserved
    case allocationOnly
}

extension NetworkMode: ExpressibleByArgument {}

extension NetworkVmnetHelper {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Starts the network plugin"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .long, help: "XPC service identifier")
        var serviceIdentifier: String

        @Option(name: .shortAndLong, help: "Network identifier")
        var id: String

        @Option(name: .long, help: "Network mode")
        var mode: NetworkMode = .nat

        @Option(name: .customLong("subnet"), help: "CIDR address for the IPv4 subnet")
        var ipv4Subnet: String?

        @Option(name: .customLong("subnet-v6"), help: "CIDR address for the IPv6 prefix")
        var ipv6Subnet: String?

        @Option(name: .long, help: "Variant of the network helper to use.")
        var variant: Variant = {
            guard #available(macOS 26, *) else {
                return .allocationOnly
            }
            return .reserved
        }()

        @Option(name: .customLong("gateway"), help: "Explicit IPv4 gateway address (optional; default derived from subnet)")
        var ipv4Gateway: String?

        @Option(name: .customLong("ip-range"), help: "Sub-CIDR of subnet from which dynamic IPv4 addresses are allocated")
        var ipv4Range: String?

        @Option(name: .customLong("aux-addresses"), help: "JSON-encoded hostname-to-IPv4 reservations")
        var auxAddressesJSON: String?

        @Option(name: .customLong("driver-opt"), help: "Free-form driver option (KEY=VALUE), repeatable")
        var driverOpts: [String] = []

        @Flag(name: .customLong("ipv6"), help: "Enable IPv6 even when no IPv6 subnet is supplied")
        var enableIPv6 = false

        var logRoot = LogRoot.path

        func run() async throws {
            let commandName = NetworkVmnetHelper._commandName
            let logPath = logRoot.map { $0.appending("\(commandName)-\(id).log") }
            let log = ServiceLogger.bootstrap(category: "NetworkVmnetHelper", metadata: ["id": "\(id)"], debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(commandName)"])
            }

            do {
                log.info("configuring XPC server")
                let ipv4Subnet = try self.ipv4Subnet.map { try CIDRv4($0) }
                let ipv6Subnet = try self.ipv6Subnet.map { try CIDRv6($0) }
                let ipv4Gateway = try self.ipv4Gateway.map { try IPv4Address($0) }
                let ipv4Range = try self.ipv4Range.map { try CIDRv4($0) }
                let auxAddresses = try Self.decodeAuxAddresses(self.auxAddressesJSON)
                let parsedDriverOpts: [String: String]?
                if driverOpts.isEmpty {
                    parsedDriverOpts = nil
                } else {
                    var collected: [String: String] = [:]
                    collected.reserveCapacity(driverOpts.count)
                    for entry in driverOpts {
                        guard let separatorIndex = entry.firstIndex(of: "=") else {
                            throw ContainerizationError(.invalidArgument, message: "driver option '\(entry)' is missing '='")
                        }
                        let key = String(entry[..<separatorIndex])
                        let value = String(entry[entry.index(after: separatorIndex)...])
                        collected[key] = value
                    }
                    parsedDriverOpts = collected
                }
                let pluginInfo = NetworkPluginInfo(
                    plugin: NetworkVmnetHelper._commandName,
                    variant: self.variant.rawValue
                )

                let configuration = try NetworkConfiguration(
                    id: id,
                    mode: mode,
                    ipv4Subnet: ipv4Subnet,
                    ipv6Subnet: ipv6Subnet,
                    ipv4Gateway: ipv4Gateway,
                    ipv4Range: ipv4Range,
                    auxAddresses: auxAddresses,
                    driverOpts: parsedDriverOpts,
                    attachable: nil,
                    enableIPv6: (self.enableIPv6 || ipv6Subnet != nil) ? true : nil,
                    pluginInfo: pluginInfo
                )
                let network = try Self.createNetwork(
                    configuration: configuration,
                    variant: self.variant,
                    log: log
                )
                try await network.start()
                let server = try await NetworkService(network: network, log: log)
                let xpc = XPCServer(
                    identifier: serviceIdentifier,
                    routes: [
                        NetworkRoutes.state.rawValue: server.state,
                        NetworkRoutes.allocate.rawValue: server.allocate,
                        NetworkRoutes.deallocate.rawValue: server.deallocate,
                        NetworkRoutes.lookup.rawValue: server.lookup,
                        NetworkRoutes.disableAllocator.rawValue: server.disableAllocator,
                    ],
                    log: log
                )

                log.info("starting XPC server")
                try await xpc.listen()
            } catch {
                log.error(
                    "helper failed",
                    metadata: [
                        "name": "\(commandName)",
                        "error": "\(error)",
                    ])
                NetworkVmnetHelper.exit(withError: error)
            }
        }

        private static func createNetwork(configuration: NetworkConfiguration, variant: Variant, log: Logger) throws -> Network {
            switch variant {
            case .allocationOnly:
                return try AllocationOnlyVmnetNetwork(configuration: configuration, log: log)
            case .reserved:
                guard #available(macOS 26, *) else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "variant ReservedVmnetNetwork is only available on macOS 26+"
                    )
                }
                return try ReservedVmnetNetwork(configuration: configuration, log: log)
            }
        }

        private static func decodeAuxAddresses(_ jsonText: String?) throws -> [String: IPv4Address]? {
            guard let jsonText, !jsonText.isEmpty else { return nil }
            guard let data = jsonText.data(using: .utf8) else {
                throw ContainerizationError(.invalidArgument, message: "aux-addresses payload is not valid UTF-8")
            }
            let raw = try JSONDecoder().decode([String: String].self, from: data)
            var decoded: [String: IPv4Address] = [:]
            decoded.reserveCapacity(raw.count)
            for (hostname, addressText) in raw {
                decoded[hostname] = try IPv4Address(addressText)
            }
            return decoded
        }
    }
}
