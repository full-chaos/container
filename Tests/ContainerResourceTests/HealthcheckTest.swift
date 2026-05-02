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
import Foundation
import Testing

@testable import ContainerResource

struct HealthcheckTest {
    @Test func cmdFormParsesAndValidates() throws {
        let h = try Healthcheck(test: ["CMD", "curl", "-f", "http://localhost"])
        #expect(h.test == ["CMD", "curl", "-f", "http://localhost"])
        #expect(h.interval == Healthcheck.defaultInterval)
        #expect(h.timeout == Healthcheck.defaultTimeout)
        #expect(h.retries == Healthcheck.defaultRetries)
        #expect(!h.isEffectivelyDisabled)
    }

    @Test func cmdShellFormParsesAndValidates() throws {
        let h = try Healthcheck(test: ["CMD-SHELL", "test -f /tmp/ready"])
        #expect(h.test == ["CMD-SHELL", "test -f /tmp/ready"])
        #expect(!h.isEffectivelyDisabled)
    }

    @Test func noneFormIsEffectivelyDisabled() throws {
        let h = try Healthcheck(test: ["NONE"])
        #expect(h.isEffectivelyDisabled)
    }

    @Test func disableFlagBypassesObserver() throws {
        let h = try Healthcheck(test: ["CMD-SHELL", "true"], disable: true)
        #expect(h.isEffectivelyDisabled)
    }

    @Test func emptyTestArrayRejected() {
        #expect {
            _ = try Healthcheck(test: [])
        } throws: { error in
            guard let err = error as? ContainerizationError else { return false }
            #expect(err.code == .invalidArgument)
            #expect(err.message.contains("must not be empty"))
            return true
        }
    }

    @Test func unknownTestKindRejected() {
        #expect {
            _ = try Healthcheck(test: ["BADKIND", "..."])
        } throws: { error in
            guard let err = error as? ContainerizationError else { return false }
            #expect(err.code == .invalidArgument)
            #expect(err.message.contains("must start with"))
            return true
        }
    }

    @Test func cmdWithoutArgumentsRejected() {
        #expect {
            _ = try Healthcheck(test: ["CMD"])
        } throws: { error in
            guard let err = error as? ContainerizationError else { return false }
            #expect(err.code == .invalidArgument)
            return true
        }
    }

    @Test func nonPositiveIntervalRejected() {
        #expect {
            _ = try Healthcheck(test: ["CMD-SHELL", "true"], interval: 0)
        } throws: { error in
            guard let err = error as? ContainerizationError else { return false }
            #expect(err.message.contains("interval"))
            return true
        }
    }

    @Test func negativeRetriesRejected() {
        #expect {
            _ = try Healthcheck(test: ["CMD-SHELL", "true"], retries: -1)
        } throws: { error in
            guard let err = error as? ContainerizationError else { return false }
            #expect(err.message.contains("retries"))
            return true
        }
    }

    @Test func probeIntervalUsesStartIntervalDuringGrace() throws {
        let h = try Healthcheck(
            test: ["CMD-SHELL", "true"],
            interval: 30,
            startPeriod: 60,
            startInterval: 5
        )
        #expect(h.probeInterval(forContainerAge: 0) == 5)
        #expect(h.probeInterval(forContainerAge: 30) == 5)
        #expect(h.probeInterval(forContainerAge: 60) == 30)
        #expect(h.probeInterval(forContainerAge: 600) == 30)
    }

    @Test func probeIntervalFallsBackToIntervalWithoutStartInterval() throws {
        let h = try Healthcheck(
            test: ["CMD-SHELL", "true"],
            interval: 30,
            startPeriod: 60
        )
        #expect(h.probeInterval(forContainerAge: 0) == 30)
        #expect(h.probeInterval(forContainerAge: 600) == 30)
    }

    @Test func roundTripThroughCodable() throws {
        let original = try Healthcheck(
            test: ["CMD-SHELL", "test -f /tmp/ready"],
            interval: 15,
            timeout: 5,
            retries: 5,
            startPeriod: 30,
            startInterval: 2,
            disable: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Healthcheck.self, from: data)
        #expect(decoded.test == original.test)
        #expect(decoded.interval == original.interval)
        #expect(decoded.timeout == original.timeout)
        #expect(decoded.retries == original.retries)
        #expect(decoded.startPeriod == original.startPeriod)
        #expect(decoded.startInterval == original.startInterval)
        #expect(decoded.disable == original.disable)
    }

    @Test func legacyContainerConfigurationDecodesWithoutHealthcheck() throws {
        let json = """
            {
                "id": "legacy",
                "image": {
                    "reference": "redis:latest",
                    "descriptor": {
                        "mediaType": "application/vnd.oci.image.manifest.v1+json",
                        "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
                        "size": 0
                    }
                },
                "initProcess": {
                    "executable": "/usr/local/bin/redis-server",
                    "arguments": [],
                    "environment": [],
                    "workingDirectory": "/",
                    "terminal": false,
                    "user": {"id": {"uid": 0, "gid": 0}},
                    "supplementalGroups": [],
                    "rlimits": []
                }
            }
            """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        #expect(decoded.healthcheck == nil)
    }
}
