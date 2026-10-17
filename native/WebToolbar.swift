// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import PortalCore
import WebKit

extension WKContentWorld {
    /// The isolated world where the core's shared script SCRIPT runs, out of
    /// the page's reach: it has no access to the page or its bridge.
    @MainActor static func portal(_ script: portal_script) -> WKContentWorld {
        .world(name: script == PORTAL_SCRIPT_LINKS ? "Portal links" : "Portal toolbar")
    }
}

/// The WebKit side of a web view's toolbar primitives (portal.h): the core's
/// contents script and its heading reports, calls of that script's
/// functions, page zoom, and WebKit's find. The core decides when to use each.
@MainActor
final class WebToolbar: NSObject, WKScriptMessageHandler {
    private weak var web: WKWebView?
    /// The view it reports as, which changes once, when a view adopts a
    /// window that a page opened.
    var target: String

    /// Run the contents script in WEB, which reports as TARGET.
    init(web: WKWebView, target: String) {
        self.web = web
        self.target = target
        super.init()
        let controller = web.configuration.userContentController
        let world = WKContentWorld.portal(PORTAL_SCRIPT_CONTENTS)
        controller.add(self, contentWorld: world, name: "toolbar")
        controller.addUserScript(WKUserScript(source: Core.script(PORTAL_SCRIPT_CONTENTS, handler: "toolbar"),
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: world))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let count = message.body as? Int else { return }
        Core.headings(target, count)
    }

    /// Call FUNCTION of SCRIPT with ARGUMENT, JSON that crosses as data.
    static func call(_ web: WKWebView, target: String, script: portal_script, function: String,
                     argument: String, token: UInt64) throws {
        guard let value = try? JSONSerialization.jsonObject(with: Data(argument.utf8), options: .fragmentsAllowed) else {
            throw NativeError.message("A script's argument must be JSON")
        }
        web.callAsyncJavaScript("return \(function)(argument)", arguments: ["argument": value],
                                in: nil, in: .portal(script)) { result in
            let value = (try? result.get()) as? Int
            Core.returned(target, token: token, value: value)
        }
    }

    static func find(_ web: WKWebView, target: String, query: String, backwards: Bool, token: UInt64) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        web.find(query, configuration: configuration) { result in
            Core.found(target, token: token, found: result.matchFound)
        }
    }
}
