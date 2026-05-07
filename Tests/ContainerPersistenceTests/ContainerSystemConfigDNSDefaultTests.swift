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

import Foundation
import Testing
import TOML

@testable import ContainerPersistence

/// Tests for the default `dns.domain` baked into `ContainerSystemConfig.DNSConfig`
/// as part of the CHAOS-1478 routing fix.
///
/// The default value (`"test"`) MUST stay in sync with the resolver file written
/// by `scripts/pkg-scripts/postinstall` (`/etc/resolver/containerization.test`).
/// If you change the default here, also update the postinstall script.
struct ContainerSystemConfigDNSDefaultTests {
    // MARK: - Default value

    /// `DNSConfig()` (no arguments) yields the default domain. This is the
    /// path used when `ContainerSystemConfig` is constructed without a TOML
    /// file (e.g. fresh install, no user config).
    @Test func testDefaultDomainIsTest() {
        let config = DNSConfig()
        #expect(config.domain == "test")
        #expect(config.domain == DNSConfig.defaultDomain)
    }

    /// Explicit `nil` is preserved — caller can intentionally clear the domain.
    /// This is needed for tests and for advanced configurations where the
    /// caller wants to skip search-domain injection entirely.
    @Test func testExplicitNilIsPreserved() {
        let config = DNSConfig(domain: nil)
        #expect(config.domain == nil)
    }

    /// Explicit non-default domain is preserved.
    @Test func testExplicitDomainIsPreserved() {
        let config = DNSConfig(domain: "example.com")
        #expect(config.domain == "example.com")
    }

    // MARK: - TOML decode

    /// TOML with no `[dns]` section at all → top-level config has the default.
    /// This is the most common case: a user with a minimal runtime-config.toml.
    @Test func testTOMLDecodeMissingDnsSectionUsesDefault() throws {
        let toml = ""
        let decoded = try TOMLDecoder().decode(ContainerSystemConfig.self, from: Data(toml.utf8))
        #expect(decoded.dns.domain == "test")
    }

    /// TOML with `[dns]` but no `domain` key → defaults to `"test"`.
    @Test func testTOMLDecodeEmptyDnsSectionUsesDefault() throws {
        let toml = """
            [dns]
            """
        let decoded = try TOMLDecoder().decode(ContainerSystemConfig.self, from: Data(toml.utf8))
        #expect(decoded.dns.domain == "test")
    }

    /// TOML with explicit `dns.domain = "foo"` → user override takes effect.
    /// This guards the "user can opt out / replace" pathway.
    @Test func testTOMLDecodeExplicitDomainOverridesDefault() throws {
        let toml = """
            [dns]
            domain = "internal.example"
            """
        let decoded = try TOMLDecoder().decode(ContainerSystemConfig.self, from: Data(toml.utf8))
        #expect(decoded.dns.domain == "internal.example")
    }

    /// TOML with explicit empty-string domain → preserved as empty string.
    /// Empty string is treated as "no domain" by the search-domain injection
    /// logic in `Utility.containerConfigFromFlags`. Decoding must NOT silently
    /// substitute the default in this case — the user explicitly opted out.
    @Test func testTOMLDecodeExplicitEmptyStringDomainIsPreserved() throws {
        let toml = """
            [dns]
            domain = ""
            """
        let decoded = try TOMLDecoder().decode(ContainerSystemConfig.self, from: Data(toml.utf8))
        #expect(decoded.dns.domain == "")
    }

    // MARK: - Top-level ContainerSystemConfig wiring

    /// `ContainerSystemConfig()` with all defaults exposes the DNS default at
    /// the top level — verifies the construction chain doesn't drop it.
    @Test func testTopLevelDefaultExposesDNSDefault() {
        let config = ContainerSystemConfig()
        #expect(config.dns.domain == "test")
    }
}
