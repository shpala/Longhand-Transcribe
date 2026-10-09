import Foundation
import Testing
@testable import LonghandKit

@Suite struct ExportNamingTests {

    @Test func namesTheFileAfterTheRecording() {
        #expect(ExportNaming.fileName(title: "Weekly sync", kind: .markdown) == "Weekly sync transcript.md")
        #expect(ExportNaming.fileName(title: "Weekly sync", kind: .text) == "Weekly sync transcript.txt")
        #expect(ExportNaming.fileName(title: "Weekly sync", kind: .json) == "Weekly sync transcript.json")
        #expect(ExportNaming.fileName(title: "Weekly sync", kind: .audio(fileExtension: "M4A")) == "Weekly sync.m4a")
    }

    @Test func aDatedTitleKeepsItsPunctuationExceptTheColon() {
        // The default take title has a colon in the time, which a file name
        // cannot carry on every system the file may land on.
        #expect(ExportNaming.fileName(title: "9 Oct 2026 at 11:02", kind: .markdown)
                == "9 Oct 2026 at 11-02 transcript.md")
        #expect(ExportNaming.fileName(title: "Q3: budget / plan?", kind: .text)
                == "Q3- budget - plan- transcript.txt")
    }

    @Test func emptyHiddenAndOverlongTitlesAreMadeSafe() {
        #expect(ExportNaming.fileName(title: "   ", kind: .markdown) == "Recording transcript.md")
        #expect(ExportNaming.fileName(title: "...secret.", kind: .markdown) == "secret transcript.md")
        let long = String(repeating: "word ", count: 40)
        let name = ExportNaming.fileName(title: long, kind: .json)
        #expect(name.hasSuffix(" transcript.json"))
        #expect(name.count <= 80 + " transcript.json".count)
        #expect(!name.hasPrefix(" "))
    }

    @Test func hebrewAndNewlinesSurvive() {
        #expect(ExportNaming.fileName(title: "פגישה\nעם דנה", kind: .markdown) == "פגישה עם דנה transcript.md")
    }
}
