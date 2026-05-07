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

/// Pure-logic helpers for DNS question-name → allocator-key translation.
///
/// Extracted to a standalone library target so that unit tests can reach the
/// logic via `@testable import APIServer` without importing the executable
/// target (`container-apiserver`), which cannot be imported by test targets
/// due to its `@main` entry point. See CHAOS-1478.
public enum DNSRegistrationKey {
    /// Converts a DNS question name into the bare allocator key used by
    /// `NetworksService.lookup(hostname:)`.
    ///
    /// Steps:
    /// 1. Strip a single trailing root-label dot (canonical FQDN → bare form).
    /// 2. If `dnsDomain` is non-nil and non-empty, strip a `".<dnsDomain>"`
    ///    suffix at a label boundary (i.e. the suffix must be preceded by `.`).
    ///
    /// - Parameters:
    ///   - questionName: The raw DNS question name (e.g. `"probe-pg.test."`)
    ///   - dnsDomain: The configured `dns.domain` value, or `nil` / `""` when
    ///     no domain suffix stripping should occur.
    /// - Returns: The bare hostname key (e.g. `"probe-pg"`).
    public static func registrationKey(for questionName: String, dnsDomain: String?) -> String {
        var key = questionName.hasSuffix(".") ? String(questionName.dropLast()) : questionName
        if let domain = dnsDomain, !domain.isEmpty, key.hasSuffix(".\(domain)") {
            key = String(key.dropLast(domain.count + 1))
        }
        return key
    }
}
