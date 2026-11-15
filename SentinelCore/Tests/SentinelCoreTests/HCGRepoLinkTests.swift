import Foundation
@testable import SentinelCore
import XCTest

final class HCGRepoLinkTests: XCTestCase {
    func testProductPageIsAFixedHTTPSAddressWithoutQueryOrIdentifiers() {
        let url = HCGRepoLink.productPage
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "repo.hakmicapitalgroup.com")
        XCTAssertEqual(url.pathComponents, ["/", "products", "hcg-sentinel"])
        XCTAssertEqual(url.absoluteString, "https://repo.hakmicapitalgroup.com/products/hcg-sentinel/")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertNil(url.port)
        XCTAssertTrue(HCGRepoLink.isOpenable(url))
    }

    func testOnlyPlainHTTPSAddressesAreOpenable() {
        for text in [
            "http://repo.hakmicapitalgroup.com/products/hcg-sentinel/",
            "https://repo.hakmicapitalgroup.com/products/hcg-sentinel/?session=abc",
            "https://repo.hakmicapitalgroup.com/products/hcg-sentinel/#device",
            "https://user:secret@repo.hakmicapitalgroup.com/",
            "https://repo.hakmicapitalgroup.com:8443/",
            "hcgsentinel://open/settings",
        ] {
            XCTAssertFalse(HCGRepoLink.isOpenable(URL(string: text)!), text)
        }
    }
}
