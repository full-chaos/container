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

@testable import ContainerAPIClient
import ContainerResource
import Testing

struct UtilityRegistrationTests {
    // MARK: - Bare-form registration (CHAOS-1478)

    /// A plain containerId with no trailing dot registers as-is.
    @Test func testBareContainerIdRegistersBareForm() throws {
        let configs = try Utility.getAttachmentConfigurations(
            containerId: "probe-pg",
            builtinNetworkId: "default",
            networks: []
        )
        #expect(configs.count == 1)
        #expect(configs[0].options.hostname == "probe-pg")
    }

    /// A containerId with a trailing dot has the dot stripped before registration.
    @Test func testTrailingDotContainerIdIsStripped() throws {
        let configs = try Utility.getAttachmentConfigurations(
            containerId: "probe-pg.",
            builtinNetworkId: "default",
            networks: []
        )
        #expect(configs.count == 1)
        #expect(configs[0].options.hostname == "probe-pg")
    }

    /// A fully-qualified containerId has exactly one trailing dot stripped;
    /// internal dots are preserved.
    @Test func testFqdnContainerIdIsStrippedToBareWithDots() throws {
        let configs = try Utility.getAttachmentConfigurations(
            containerId: "probe-pg.svc.cluster.local.",
            builtinNetworkId: "default",
            networks: []
        )
        #expect(configs.count == 1)
        #expect(configs[0].options.hostname == "probe-pg.svc.cluster.local")
    }

    /// When no networks are specified the function falls back to the builtin network.
    @Test func testEmptyNetworksFallsBackToBuiltinNetwork() throws {
        let configs = try Utility.getAttachmentConfigurations(
            containerId: "mycontainer",
            builtinNetworkId: "bridge0",
            networks: []
        )
        #expect(configs.count == 1)
        #expect(configs[0].network == "bridge0")
    }

    /// When multiple networks are provided (macOS 26+), every returned
    /// AttachmentConfiguration carries the same bare registration hostname.
    @Test func testMultipleNetworksAllUseSameRegistrationHostname() throws {
        guard #available(macOS 26, *) else {
            // Non-default multi-network configuration requires macOS 26+.
            return
        }
        let networks = [
            Parser.ParsedNetwork(name: "net0"),
            Parser.ParsedNetwork(name: "net1"),
        ]
        let configs = try Utility.getAttachmentConfigurations(
            containerId: "probe-pg",
            builtinNetworkId: "default",
            networks: networks
        )
        #expect(configs.count == 2)
        let hostnames = configs.map(\.options.hostname)
        #expect(hostnames.allSatisfy { $0 == "probe-pg" })
    }
}
