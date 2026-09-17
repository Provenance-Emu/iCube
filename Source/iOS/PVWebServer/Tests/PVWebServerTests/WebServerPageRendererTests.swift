import XCTest
@testable import PVWebServer

final class WebServerPageRendererTests: XCTestCase {
    func testRenderSubstitutesEveryToken() {
        let out = WebServerPageRenderer.render("a {{X}} b {{Y}} {{X}}", variables: ["X": "1", "Y": "2"])
        XCTAssertEqual(out, "a 1 b 2 1")
    }

    /// A value that itself looks like a token used to be re-expanded by the next iteration of
    /// the substitution loop (dictionary order decided whether it happened).
    func testRenderDoesNotReSubstituteAcrossValues() {
        XCTAssertEqual(WebServerPageRenderer.render("a {{X}}", variables: ["X": "{{Y}}", "Y": "no"]),
                       "a {{Y}}")
    }

    /// Order-independent proof of the same bug: with a cycle, whichever key the old loop
    /// happened to visit first, the other pass re-expanded its output.
    func testRenderIsSinglePassWithCyclicValues() {
        XCTAssertEqual(WebServerPageRenderer.render("{{X}} {{Y}}", variables: ["X": "{{Y}}", "Y": "{{X}}"]),
                       "{{Y}} {{X}}")
    }

    func testRenderLeavesUnknownTokensAlone() {
        XCTAssertEqual(WebServerPageRenderer.render("{{KNOWN}} {{MYSTERY}}", variables: ["KNOWN": "ok"]),
                       "ok {{MYSTERY}}")
    }

    /// `{{CURRENT_PATH}}` is injected into a `<script>` block, so a folder named
    /// `</script>…` must not be able to close it.
    func testJSEscapedNeutralisesScriptClose() {
        let escaped = "</script><script>alert(1)</script>".jsEscaped
        XCTAssertFalse(escaped.contains("</script>"))
        XCTAssertTrue(escaped.contains("<\\/script>"))
    }

    func testJSEscapedNeutralisesLineTerminators() {
        XCTAssertEqual("a\nb".jsEscaped, "a\\nb")
        XCTAssertEqual("a\rb".jsEscaped, "a\\rb")
        XCTAssertEqual("a\u{2028}b".jsEscaped, "a\\u2028b")
        XCTAssertEqual("a\u{2029}b".jsEscaped, "a\\u2029b")
    }

    func testUploadPageEscapesScriptCloseInCurrentPath() {
        let html = WebServerPageRenderer.uploadPage(
            appName: "iCube", ipAddress: "10.0.0.5", portSuffix: "",
            fileRows: "<tr><td>row</td></tr>",
            currentPath: "</script><script>alert(1)</script>")
        XCTAssertTrue(html.contains("<\\/script>"), "the injected path must not close the script block")
        // The payload survives verbatim inside the JS string literal, which is harmless — what
        // matters is that it can no longer terminate the <script> element.
        XCTAssertFalse(html.contains("</script><script>"))
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
