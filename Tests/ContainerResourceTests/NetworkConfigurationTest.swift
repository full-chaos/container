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
import Testing

@testable import ContainerResource

struct NetworkConfigurationTest {
    let defaultNetworkPluginInfo = NetworkPluginInfo(plugin: "container-network-vmnet")

    @Test func testValidationOkDefaults() throws {
        let id = "foo"
        _ = try NetworkConfiguration(
            id: id,
            mode: .nat,
            pluginInfo: defaultNetworkPluginInfo
        )
    }

    @Test func testValidationGoodId() throws {
        let ids = [
            String(repeating: "0", count: 63),
            "0",
            "0-_.1",
        ]
        for id in ids {
            let ipv4Subnet = try CIDRv4("192.168.64.1/24")
            let labels = try ResourceLabels([
                "foo": "bar",
                "baz": String(repeating: "0", count: 4096 - "baz".count - "=".count),
            ])
            _ = try NetworkConfiguration(
                id: id,
                mode: .nat,
                ipv4Subnet: ipv4Subnet,
                labels: labels,
                pluginInfo: defaultNetworkPluginInfo
            )
        }
    }

    @Test func testValidationBadId() throws {
        let ids = [
            String(repeating: "0", count: 64),
            "-foo",
            "foo_",
            "Foo",
        ]
        for id in ids {
            let ipv4Subnet = try CIDRv4("192.168.64.1/24")
            let labels = try ResourceLabels([
                "foo": "bar",
                "baz": String(repeating: "0", count: 4096 - "baz".count - "=".count),
            ])
            #expect {
                _ = try NetworkConfiguration(
                    id: id,
                    mode: .nat,
                    ipv4Subnet: ipv4Subnet,
                    labels: labels,
                    pluginInfo: defaultNetworkPluginInfo
                )
            } throws: { error in
                guard let err = error as? ContainerizationError else { return false }
                #expect(err.code == .invalidArgument)
                #expect(err.message.starts(with: "invalid network ID"))
                return true
            }
        }
    }

    @Test func testGatewayWithinSubnet() throws {
        let ipv4Subnet = try CIDRv4("10.0.0.0/24")
        let gateway = try IPv4Address("10.0.0.254")
        _ = try NetworkConfiguration(
            id: "net",
            mode: .nat,
            ipv4Subnet: ipv4Subnet,
            ipv4Gateway: gateway,
            pluginInfo: defaultNetworkPluginInfo
        )
    }

    @Test func testGatewayOutsideSubnetRejected() throws {
        let ipv4Subnet = try CIDRv4("10.0.0.0/24")
        let gateway = try IPv4Address("10.0.1.1")
        #expect {
            _ = try NetworkConfiguration(
                id: "net",
                mode: .nat,
                ipv4Subnet: ipv4Subnet,
                ipv4Gateway: gateway,
                pluginInfo: defaultNetworkPluginInfo
            )
        } throws: { error in
            guard let err = error as? ContainerizationError else { return false }
            #expect(err.code == .invalidArgument)
            #expect(err.message.contains("is not within IPv4 subnet"))
            return true
        }
    }

    @Test func testIPRangeWithinSubnet() throws {
        let ipv4Subnet = try CIDRv4("10.0.0.0/24")
        let ipv4Range = try CIDRv4("10.0.0.128/28")
        _ = try NetworkConfiguration(
            id: "net",
            mode: .nat,
            ipv4Subnet: ipv4Subnet,
            ipv4Range: ipv4Range,
            pluginInfo: defaultNetworkPluginInfo
        )
    }

    @Test func testIPRangeOutsideSubnetRejected() throws {
        let ipv4Subnet = try CIDRv4("10.0.0.0/24")
        let ipv4Range = try CIDRv4("10.0.1.0/28")
        #expect {
            _ = try NetworkConfiguration(
                id: "net",
                mode: .nat,
                ipv4Subnet: ipv4Subnet,
                ipv4Range: ipv4Range,
                pluginInfo: defaultNetworkPluginInfo
            )
        } throws: { error in
            guard let err = error as? ContainerizationError else { return false }
            #expect(err.code == .invalidArgument)
            #expect(err.message.contains("ip-range"))
            return true
        }
    }

    @Test func testAuxAddressesWithinSubnet() throws {
        let ipv4Subnet = try CIDRv4("10.0.0.0/24")
        let aux: [String: IPv4Address] = [
            "db": try IPv4Address("10.0.0.10"),
            "web": try IPv4Address("10.0.0.20"),
        ]
        _ = try NetworkConfiguration(
            id: "net",
            mode: .nat,
            ipv4Subnet: ipv4Subnet,
            auxAddresses: aux,
            pluginInfo: defaultNetworkPluginInfo
        )
    }

    @Test func testAuxAddressOutsideSubnetRejected() throws {
        let ipv4Subnet = try CIDRv4("10.0.0.0/24")
        let aux: [String: IPv4Address] = [
            "oops": try IPv4Address("172.16.0.1")
        ]
        #expect {
            _ = try NetworkConfiguration(
                id: "net",
                mode: .nat,
                ipv4Subnet: ipv4Subnet,
                auxAddresses: aux,
                pluginInfo: defaultNetworkPluginInfo
            )
        } throws: { error in
            guard let err = error as? ContainerizationError else { return false }
            #expect(err.code == .invalidArgument)
            #expect(err.message.contains("aux-address"))
            return true
        }
    }

    @Test func testNewFieldsRoundTripThroughCodable() throws {
        let aux: [String: IPv4Address] = ["db": try IPv4Address("10.0.0.10")]
        let original = try NetworkConfiguration(
            id: "net",
            mode: .nat,
            ipv4Subnet: try CIDRv4("10.0.0.0/24"),
            ipv4Gateway: try IPv4Address("10.0.0.254"),
            ipv4Range: try CIDRv4("10.0.0.128/28"),
            auxAddresses: aux,
            driverOpts: ["key": "value"],
            attachable: true,
            enableIPv6: true,
            pluginInfo: defaultNetworkPluginInfo
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NetworkConfiguration.self, from: data)

        #expect(decoded.ipv4Gateway?.description == "10.0.0.254")
        #expect(decoded.ipv4Range?.description == original.ipv4Range?.description)
        #expect(decoded.auxAddresses?["db"]?.description == "10.0.0.10")
        #expect(decoded.driverOpts == ["key": "value"])
        #expect(decoded.attachable == true)
        #expect(decoded.enableIPv6 == true)
    }

    @Test func testLegacyConfigurationDecodesWithoutNewFields() throws {
        // Pre-existing on-disk configurations were persisted without the new
        // optional fields. Verify they decode cleanly with `nil` defaults.
        let legacyJSON = """
            {
                \"id\": \"legacy\",
                \"mode\": \"nat\",
                \"creationDate\": 0,
                \"labels\": {},
                \"pluginInfo\": {\"plugin\": \"container-network-vmnet\"}
            }
            """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NetworkConfiguration.self, from: data)

        #expect(decoded.ipv4Gateway == nil)
        #expect(decoded.ipv4Range == nil)
        #expect(decoded.auxAddresses == nil)
        #expect(decoded.driverOpts == nil)
        #expect(decoded.attachable == nil)
        #expect(decoded.enableIPv6 == nil)
    }

}
