import XCTest
@testable import PVWebServer

final class WebServerPageRendererTests: XCTestCase {
    func testRenderSubstitutesEveryToken() {
        let out = WebServerPageRenderer.render("a {{X}} b {{Y}} {{X}}", variables: ["X": "1", "Y": "2"])
        XCTAssertEqual(out, "a 1 b 2 1")
    }

    func testResourcesAreBundled() {
        for (name, ext) in [("upload-page", "html"), ("upload-page", "css"), ("upload-page", "js"), ("nav-fragment", "html")] {
            XCTAssertNotNil(WebServerPageRenderer.loadResource(name: name, ext: ext), "\(name).\(ext) missing from Bundle.module")
        }
    }

    func testUploadPageHasNoUnrenderedTokensAndUsesAppName() {
        let html = WebServerPageRenderer.uploadPage(appName: "iCube", ipAddress: "10.0.0.5", portSuffix: "",
                                                    fileRows: "<tr><td>row</td></tr>", currentPath: "Wii")
        XCTAssertFalse(html.contains("{{"), "unrendered token in page")
        XCTAssertTrue(html.contains("iCube"))
        XCTAssertTrue(html.contains("http://10.0.0.5/"))
        XCTAssertTrue(html.contains("<tr><td>row</td></tr>"))
        XCTAssertTrue(html.contains("Wii"))
        XCTAssertFalse(html.contains("iFly"))
    }

    func testMissingResourceRendersVisibleError() {
        let html = WebServerPageRenderer.errorPage(missing: "upload-page.html")
        XCTAssertTrue(html.contains("upload-page.html"))
    }
}
