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

import SystemPackage
import Testing

@testable import ContainerCommands

struct FilePathAbsoluteTests {
    @Test
    func absoluteInputReturnedAsIs() {
        let result = FilePath.absolute("/usr/local/bin/tool")
        #expect(result.string == "/usr/local/bin/tool")
    }

    @Test
    func absoluteInputWithDotDotNormalized() {
        let result = FilePath.absolute("/usr/local/../bin/tool")
        #expect(result.string == "/usr/bin/tool")
    }

    @Test
    func relativeInputResolvedAgainstCwd() {
        let result = FilePath.absolute("images/foo.tar", relativeTo: FilePath("/tmp"))
        #expect(result.string == "/tmp/images/foo.tar")
    }

    @Test
    func relativeInputWithDotDotNormalized() {
        let result = FilePath.absolute("../foo.tar", relativeTo: FilePath("/tmp/sub"))
        #expect(result.string == "/tmp/foo.tar")
    }

    @Test
    func singleFilenameResolvedAgainstCwd() {
        let result = FilePath.absolute("archive.tar", relativeTo: FilePath("/home/user"))
        #expect(result.string == "/home/user/archive.tar")
    }

    @Test
    func dotDotPastRootClampsAtRoot() {
        // POSIX lexicallyNormalized() clamps excess `..` components at `/`
        let result = FilePath.absolute("../../../../../../etc/passwd", relativeTo: FilePath("/tmp"))
        #expect(result.string == "/etc/passwd")
    }

    @Test
    func emptyStringInputResolvesToCwd() {
        // `--output ""` is silently treated as "use current directory"
        let result = FilePath.absolute("", relativeTo: FilePath("/tmp"))
        #expect(result.string == "/tmp")
    }

    @Test
    func rootPathPreservedThroughNormalization() {
        // An absolute `/` input should survive lexical normalization unchanged
        let result = FilePath.absolute("/", relativeTo: FilePath("/tmp"))
        #expect(result.string == "/")
    }

    @Test
    func trailingSlashDroppedByNormalization() {
        // FilePath drops trailing slashes during lexical normalization
        let result = FilePath.absolute("/tmp/", relativeTo: FilePath("/somewhere"))
        #expect(result.string == "/tmp")
    }
}
