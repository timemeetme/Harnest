import XCTest
@testable import Harnest

final class ProvidersCatalogTests: XCTestCase {

    func testCatalogHasNoDuplicates() {
        XCTAssertEqual(Set(Providers.all).count, Providers.all.count)
    }

    func testEveryCatalogEntryHasMeta() {
        for p in Providers.all {
            XCTAssertNotNil(Providers.metaOf(p), "missing meta for \(p)")
        }
    }

    func testPresetProvidersHaveBaseUrlAndModels() {
        for p in Providers.all where p != Providers.custom {
            let meta = Providers.metaOf(p)
            XCTAssertEqual(meta?.baseUrl.hasPrefix("https://"), true, p)
            XCTAssertEqual(meta?.models.isEmpty, false, p)
            XCTAssertEqual(meta?.defaultModel.isEmpty, false, p)
        }
    }

    func testReasoningEffortValidation() {
        for id in ReasoningEfforts.ids {
            XCTAssertTrue(ReasoningEfforts.isValid(id))
        }
        XCTAssertFalse(ReasoningEfforts.isValid("bogus"))
        XCTAssertTrue(ReasoningEfforts.isValid(nil))
    }
}
