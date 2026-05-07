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

// Judgment call: `container-apiserver` is an executable target with `@main`
// and cannot be imported by test targets.  The `registrationKey` logic was
// therefore extracted to `DNSRegistrationKey` in the `APIServer` library
// target (`Sources/APIServerLib/`), which `ContainerDNSHandler` delegates to.
// These tests exercise `DNSRegistrationKey.registrationKey(for:dnsDomain:)`
// directly, which is the canonical implementation of the CHAOS-1478 fix.

@testable import APIServer
import Testing

struct ContainerDNSHandlerRegistrationKeyTest {
    // MARK: - Trailing-dot stripping (dnsDomain: nil)

    /// A trailing root-label dot is stripped; bare form is returned.
    @Test func testStripsTrailingDot() {
        let key = DNSRegistrationKey.registrationKey(for: "foo.", dnsDomain: nil)
        #expect(key == "foo")
    }

    /// A name without a trailing dot passes through unchanged.
    @Test func testNoDotIsPassthrough() {
        let key = DNSRegistrationKey.registrationKey(for: "foo", dnsDomain: nil)
        #expect(key == "foo")
    }

    // MARK: - dns.domain suffix stripping

    /// Canonical FQDN with configured domain suffix → bare container name.
    @Test func testStripsConfiguredDnsDomain() {
        let key = DNSRegistrationKey.registrationKey(for: "probe-pg.test.", dnsDomain: "test")
        #expect(key == "probe-pg")
    }

    /// Already-bare query (no trailing dot) that matches the suffix → stripped.
    @Test func testStripsBareDnsDomainSuffix() {
        let key = DNSRegistrationKey.registrationKey(for: "probe-pg.test", dnsDomain: "test")
        #expect(key == "probe-pg")
    }

    /// When dnsDomain is nil, no suffix stripping occurs.
    @Test func testDoesNotStripUnconfiguredDomain() {
        let key = DNSRegistrationKey.registrationKey(for: "probe-pg.test.", dnsDomain: nil)
        #expect(key == "probe-pg.test")
    }

    /// An empty-string dnsDomain is treated as "not configured" — no suffix stripping.
    @Test func testEmptyDnsDomainIsTreatedAsNotConfigured() {
        let key = DNSRegistrationKey.registrationKey(for: "probe-pg.test.", dnsDomain: "")
        #expect(key == "probe-pg.test")
    }

    // MARK: - Boundary matching

    /// The suffix is only stripped when preceded by a dot (label boundary).
    /// "footest." does NOT end with ".test", so no domain stripping occurs —
    /// only the trailing dot is removed.
    @Test func testDomainSuffixOnlyStripsAtBoundary() {
        let key = DNSRegistrationKey.registrationKey(for: "footest.", dnsDomain: "test")
        #expect(key == "footest")
    }

    /// A name whose suffix does not match the configured domain gets only the
    /// trailing dot stripped.
    @Test func testNonMatchingNameIsPassthrough() {
        let key = DNSRegistrationKey.registrationKey(for: "foo.example.com.", dnsDomain: "test")
        #expect(key == "foo.example.com")
    }
}
