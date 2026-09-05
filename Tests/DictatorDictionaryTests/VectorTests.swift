import Foundation
import XCTest

@testable import DictatorDictionary

/// Runs the shared behavioural contract in `shared/dictionary-test-vectors.json`.
///
/// The Windows app reimplements this logic in C# and runs the identical file. That's the
/// only thing keeping two independent implementations honest — there's no shared binary, and
/// no Windows machine to check against by hand.
final class VectorTests: XCTestCase {
    struct Vectors: Decodable {
        let version: Int
        let cases: [Case]
    }

    struct Case: Decodable {
        let name: String
        let entries: [Entry]
        let input: String
        let expected: String
        let expectedCorrections: [ExpectedCorrection]
    }

    struct Entry: Decodable {
        let kind: String
        var hear: String?
        let write: String
        var isEnabled: Bool?

        var asEntry: DictionaryEntry {
            DictionaryEntry(
                kind: kind == "correction" ? .correction : .term,
                write: write,
                hear: hear ?? "",
                isEnabled: isEnabled ?? true
            )
        }
    }

    struct ExpectedCorrection: Decodable {
        let to: String
        let count: Int
    }

    static func loadVectors() throws -> Vectors {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "dictionary-test-vectors", withExtension: "json")
        )
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testVectors() throws {
        let vectors = try Self.loadVectors()
        XCTAssertTrue(vectors.cases.isEmpty == false)

        for testCase in vectors.cases {
            let corrector = DictionaryCorrector(entries: testCase.entries.map { $0.asEntry })
            let (text, applied) = corrector.apply(to: testCase.input)

            XCTAssertTrue(text == testCase.expected, "\(testCase.name): text")
            XCTAssertTrue(
                applied.count == testCase.expectedCorrections.count,
                "\(testCase.name): correction count — got \(applied.map { $0.to })"
            )

            // Order-insensitive: which rule fires first is an implementation detail of the
            // longest-first sort, but *what* fired and how often is contractual.
            for expected in testCase.expectedCorrections {
                let match = applied.first { $0.to == expected.to }
                XCTAssertTrue(match != nil, "\(testCase.name): expected a correction to “\(expected.to)”")
                XCTAssertTrue(match?.count == expected.count, "\(testCase.name): count for “\(expected.to)”")
            }
        }
    }

    func testBiasList() {
        let entries = (0..<100).map { DictionaryEntry.term("Word\($0)") }
            + [DictionaryEntry.term("Word0")]
        let phrases = DictionaryCorrector.biasPhrases(from: entries)

        XCTAssertTrue(phrases.count == DictionaryCorrector.biasLimit)
        XCTAssertTrue(Set(phrases).count == phrases.count)
    }

    func testBiasSkipsDisabled() {
        let entries = [
            DictionaryEntry(kind: .term, write: "Kept"),
            DictionaryEntry(kind: .term, write: "Skipped", isEnabled: false),
        ]
        XCTAssertTrue(DictionaryCorrector.biasPhrases(from: entries) == ["Kept"])
    }

    func testWarnsOnCommonWord() {
        let entry = DictionaryEntry.correction(hear: "cloud", write: "Claude")
        XCTAssertTrue(DictionaryWarning.check(entry).isEmpty == false)
    }

    func testDoesNotWarnOnDistinctivePhrase() {
        let entry = DictionaryEntry.correction(hear: "clawed code", write: "Claude Code")
        XCTAssertTrue(DictionaryWarning.check(entry).isEmpty)
    }
}
