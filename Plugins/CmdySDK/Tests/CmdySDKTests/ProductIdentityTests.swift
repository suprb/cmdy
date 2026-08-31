import XCTest
@testable import CmdySDK

final class ProductIdentityTests: XCTestCase {
    func testConfigurationDirectoryHonorsTheHostInstanceOverride() {
        let isolated = "/private/tmp/cmdy-sdk-configuration-test"
        XCTAssertEqual(
            HostProductIdentity.configurationDirectory(in: [
                "CMDY_CONFIG_DIR": isolated,
            ]).path,
            isolated)
    }

    func testConfigurationDirectoryAcceptsTheProductNeutralOverride() {
        let isolated = "/private/tmp/cmdy-sdk-product-configuration-test"
        XCTAssertEqual(
            HostProductIdentity.configurationDirectory(in: [
                "PRODUCT_CONFIG_DIR": isolated,
            ]).path,
            isolated)
    }
}
