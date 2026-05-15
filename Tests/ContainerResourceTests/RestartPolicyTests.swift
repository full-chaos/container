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

@testable import ContainerResource

/// Unit-level coverage for the wire shape of ``RestartPolicy`` and the
/// forward-compatibility guarantees of ``ContainerCreateOptions``.
///
/// `TestCLIRunRestart` already covers end-to-end behavior against a live
/// daemon. These tests cover the contract one layer down — JSON shape and
/// legacy-blob compatibility — so a future contributor cannot regress the
/// `decodeIfPresent` default without a unit-level red flag.
struct RestartPolicyTests {
    // MARK: - RestartPolicy round-trip

    @Test
    func encodesAsBareString() throws {
        let data = try JSONEncoder().encode(RestartPolicy.always)
        let s = String(decoding: data, as: UTF8.self)
        #expect(s == "\"always\"")
    }

    @Test
    func decodesEveryCase() throws {
        let cases: [RestartPolicy] = [.no, .onFailure, .always]
        for policy in cases {
            let data = try JSONEncoder().encode(policy)
            let decoded = try JSONDecoder().decode(RestartPolicy.self, from: data)
            #expect(decoded == policy)
        }
    }

    @Test
    func rejectsUnknownString() {
        // Compose-spec includes `unless-stopped`; this PR deliberately does
        // not. The decoder must reject it so downstream tooling that emits
        // a fuller mode set fails loudly instead of silently degrading.
        let bogus = Data("\"unless-stopped\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RestartPolicy.self, from: bogus)
        }
    }

    // MARK: - ContainerCreateOptions forward-compat

    /// `options.json` blobs written by daemon versions that predate
    /// `restartPolicy` MUST still decode — defaulting to `.no`. This is the
    /// wire-compatibility invariant the PR description promises and the
    /// reason ``ContainerCreateOptions/init(from:)`` uses
    /// `decodeIfPresent`. Removing that default would silently break every
    /// existing container's `options.json` on disk.
    @Test
    func decodesLegacyOptionsWithoutRestartPolicy() throws {
        let legacy = Data(#"{"autoRemove":false}"#.utf8)
        let options = try JSONDecoder().decode(ContainerCreateOptions.self, from: legacy)
        #expect(options.autoRemove == false)
        #expect(options.restartPolicy == .no)
    }

    @Test
    func decodesLegacyOptionsWithAutoRemove() throws {
        let legacy = Data(#"{"autoRemove":true}"#.utf8)
        let options = try JSONDecoder().decode(ContainerCreateOptions.self, from: legacy)
        #expect(options.autoRemove == true)
        #expect(options.restartPolicy == .no)
    }

    @Test
    func roundTripPreservesRestartPolicy() throws {
        let original = ContainerCreateOptions(autoRemove: false, restartPolicy: .onFailure)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContainerCreateOptions.self, from: data)
        #expect(decoded.autoRemove == original.autoRemove)
        #expect(decoded.restartPolicy == original.restartPolicy)
    }

    @Test
    func encodedJSONIncludesRestartPolicyField() throws {
        let options = ContainerCreateOptions(autoRemove: false, restartPolicy: .always)
        let data = try JSONEncoder().encode(options)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"restartPolicy\":\"always\""))
    }

    @Test
    func defaultStaticIsNoRestart() {
        #expect(ContainerCreateOptions.default.restartPolicy == .no)
        #expect(ContainerCreateOptions.default.autoRemove == false)
    }
}
