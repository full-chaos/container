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

/// Coverage for the SDK shape that PR #13 introduces. Wire compatibility is
/// the contract under test: the daemon does not enforce restart policy yet,
/// so behavior tests live with the future restart manager (upstream
/// apple/container#1258), not here.
struct RestartPolicyTests {
    // MARK: - RestartPolicy round-trip

    @Test
    func testEncodesAsBareString() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(RestartPolicy.always)
        let s = String(decoding: data, as: UTF8.self)
        #expect(s == "\"always\"")
    }

    @Test
    func testDecodesEveryCase() throws {
        let decoder = JSONDecoder()
        for policy in RestartPolicy.allCases {
            let data = try JSONEncoder().encode(policy)
            let decoded = try decoder.decode(RestartPolicy.self, from: data)
            #expect(decoded == policy)
        }
    }

    @Test
    func testRejectsUnknownString() {
        let bogus = Data("\"unless-stopped\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RestartPolicy.self, from: bogus)
        }
    }

    // MARK: - ContainerCreateOptions forward-compat

    /// JSON written by a daemon version that predates `restartPolicy` MUST
    /// still decode — defaulting to `.no`. This is the wire-compatibility
    /// invariant the PR description promises.
    @Test
    func testDecodesLegacyOptionsWithoutRestartPolicy() throws {
        let legacy = Data(#"{"autoRemove":false}"#.utf8)
        let options = try JSONDecoder().decode(ContainerCreateOptions.self, from: legacy)
        #expect(options.autoRemove == false)
        #expect(options.restartPolicy == .no)
    }

    @Test
    func testDecodesLegacyOptionsWithAutoRemoveAndRootFsOverride() throws {
        // Older clients may emit only autoRemove + rootFsOverride. rootFsOverride
        // is itself optional and may not appear; we test the canonical legacy
        // shape (just autoRemove).
        let legacy = Data(#"{"autoRemove":true}"#.utf8)
        let options = try JSONDecoder().decode(ContainerCreateOptions.self, from: legacy)
        #expect(options.autoRemove == true)
        #expect(options.rootFsOverride == nil)
        #expect(options.restartPolicy == .no)
    }

    @Test
    func testRoundTripPreservesRestartPolicy() throws {
        let original = ContainerCreateOptions(autoRemove: false, restartPolicy: .onFailure)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContainerCreateOptions.self, from: data)
        #expect(decoded.autoRemove == original.autoRemove)
        #expect(decoded.restartPolicy == original.restartPolicy)
    }

    @Test
    func testEncodedJSONIncludesRestartPolicyField() throws {
        let options = ContainerCreateOptions(autoRemove: false, restartPolicy: .always)
        let data = try JSONEncoder().encode(options)
        let json = String(decoding: data, as: UTF8.self)
        // Field present and lowercase per CodingKeys + raw value.
        #expect(json.contains("\"restartPolicy\":\"always\""))
    }

    @Test
    func testDefaultStaticHasNoRestart() {
        #expect(ContainerCreateOptions.default.restartPolicy == .no)
        #expect(ContainerCreateOptions.default.autoRemove == false)
    }
}
