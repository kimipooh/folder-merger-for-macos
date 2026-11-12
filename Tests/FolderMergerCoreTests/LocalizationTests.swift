import XCTest
import Foundation
@testable import FolderMergerCore

final class LocalizationTests: XCTestCase {
    func testUnsavedExtendedAttributesUseNewDefaultWithoutWriting() {
        withDefaults { defaults in
            XCTAssertTrue(MergeOptions().extendedAttributes)
            XCTAssertTrue(MergePreferences.preserveExtendedAttributes(in: defaults))
            XCTAssertNil(defaults.object(forKey: "merge.preserveExtendedAttributes"))
        }
    }

    func testSamePathPolicyDefaultsAndSavedValues() {
        withDefaults { defaults in
            XCTAssertEqual(MergeOptions().samePathPolicy, .stop)
            XCTAssertEqual(MergePreferences.samePathPolicy(in: defaults), .stop)
            XCTAssertNil(defaults.object(forKey: "merge.samePathPolicy"))
            defaults.set("invalid", forKey: "merge.samePathPolicy")
            XCTAssertEqual(MergePreferences.samePathPolicy(in: defaults), .stop)
            defaults.set(42, forKey: "merge.samePathPolicy")
            XCTAssertEqual(MergePreferences.samePathPolicy(in: defaults), .stop)
            for policy in SamePathPolicy.allCases {
                defaults.set(policy.rawValue, forKey: "merge.samePathPolicy")
                XCTAssertEqual(MergePreferences.samePathPolicy(in: defaults), policy)
            }
        }
    }

    func testSavedFalseIsPreserved() {
        withDefaults { defaults in
            defaults.set(false, forKey: "merge.preserveExtendedAttributes")
            XCTAssertFalse(MergePreferences.preserveExtendedAttributes(in: defaults))
            XCTAssertEqual(defaults.object(forKey: "merge.preserveExtendedAttributes") as? Bool, false)
        }
    }

    func testSavedTrueIsPreserved() {
        withDefaults { defaults in
            defaults.set(true, forKey: "merge.preserveExtendedAttributes")
            XCTAssertTrue(MergePreferences.preserveExtendedAttributes(in: defaults))
            XCTAssertEqual(defaults.object(forKey: "merge.preserveExtendedAttributes") as? Bool, true)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "FolderMergerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    func testCoreResourcesLoadBothLanguagesAndPreserveArguments() throws {
        for (language, status, date, counts) in [
            ("en", "Completed with warnings", "Modification date",
             "Copied: 2 · Identical files skipped: 1 · Warnings: 3 · Errors: 0"),
            ("ja", "警告ありで完了", "変更日",
             "コピー 2 件・同一ファイル省略 1 件・警告 3 件・エラー 0 件")
        ] {
            let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            func text(_ key: String, _ args: CVarArg...) -> String {
                String(format: bundle.localizedString(forKey: key, value: nil, table: nil),
                       locale: Locale(identifier: language), arguments: args)
            }
            XCTAssertEqual(text("Completed with warnings"), status)
            XCTAssertEqual(text("Modification date"), date)
            XCTAssertEqual(text("Copied: %lld · Identical files skipped: %lld · Warnings: %lld · Errors: %lld",
                                2, 1, 3, 0), counts)
            XCTAssertEqual(text("%@: %@", text("Modification date"), "ENOTSUP"), "\(date): ENOTSUP")
            let source = "/synthetic/写真%20.jpg"
            let error = text("Cannot set attribute %@ (relative path: %@)", date, source)
            XCTAssertTrue(error.contains(date))
            XCTAssertTrue(error.contains(source))
            print("Localization \(language): \(status); \(counts); \(date): ENOTSUP")
        }
    }

    func testBothLanguagesCoverEveryKeyAndMatchFormatArguments() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["App/Localizable.xcstrings", "Sources/FolderMergerCore/Resources/Localizable.xcstrings"] {
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(file))) as? [String: Any])
            XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
            let entries = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
            XCTAssertFalse(entries.isEmpty)
            for (key, entry) in entries {
                let localizations = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]], key)
                for language in ["en", "ja"] {
                    let localization = try XCTUnwrap(localizations[language], "\(language): \(key)")
                    let values = stringValues(localization)
                    XCTAssertFalse(values.isEmpty, "\(language): \(key)")
                    for value in values {
                        XCTAssertFalse(value.isEmpty, key)
                        XCTAssertEqual(placeholders(value), placeholders(key), "\(language): \(key)")
                    }
                }
            }
        }
    }

    private func stringValues(_ object: [String: Any]) -> [String] {
        if let unit = object["stringUnit"] as? [String: String], let value = unit["value"] { return [value] }
        return object.values.flatMap { ($0 as? [String: Any]).map(stringValues) ?? [] }
    }

    func testCompiledPluralFormsInBothLanguages() throws {
        for language in ["en", "ja"] {
            let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let format = bundle.localizedString(forKey: " (%lld bytes)", value: nil, table: nil)
            XCTAssertEqual(String(format: format, locale: Locale(identifier: language), arguments: [Int64(1)]),
                           language == "en" ? " (1 byte)" : "（1 バイト）")
            XCTAssertEqual(String(format: format, locale: Locale(identifier: language), arguments: [Int64(2)]),
                           language == "en" ? " (2 bytes)" : "（2 バイト）")
        }
    }

    private func placeholders(_ value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?(?:lld|@)")
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).map {
            String(value[Range($0.range, in: value)!])
        }.sorted()
    }
}
