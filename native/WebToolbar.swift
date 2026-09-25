// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WebKit

/// Page helpers run in an isolated world, with no access to the editor bridge.
@MainActor
final class WebToolbar: NSObject, WKScriptMessageHandler {
    static let zoomSteps = [50.0, 67, 75, 85, 100, 110, 125, 150, 175, 200, 250, 300]
    private static let world = WKContentWorld.world(name: "Portal toolbar")
    let model: ToolbarModel
    private weak var web: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private var generation = 0
    private var searched = ""
    private var searchQueue: [(String, Bool)] = []
    private var searching = false

    init(web: WKWebView, preview: Bool) {
        self.web = web
        model = ToolbarModel(preview ? .preview : .web)
        super.init()
        model.action = { [weak self] in try self?.perform($0) }
        model.search = { [weak self] in self?.find($0, backwards: $1) }
        observations = [web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.navigationChanged() }
        }, web.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.navigationChanged() }
        }]
        let controller = web.configuration.userContentController
        controller.add(self, contentWorld: Self.world, name: "toolbar")
        controller.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
    }

    func loaded() {
        generation += 1
        searchQueue.removeAll()
        searched = ""
        model.matchCount = 0
        model.matchIndex = 0
        if model.kind == .preview {
            web?.callAsyncJavaScript("return portalToolbar.toc(open)", arguments: ["open": model.tocOpen],
                                     in: nil, in: Self.world) { [weak self] result in
                guard let self else { return }
                if case .success(let count as Int) = result { self.model.hasHeadings = count > 0 }
                self.model.changed?()
            }
        }
        if model.finding { find(model.query, backwards: false) }
    }

    private func navigationChanged() {
        model.canGoBack = web?.canGoBack ?? false
        model.canGoForward = web?.canGoForward ?? false
        model.changed?()
    }

    private func perform(_ action: String) throws {
        guard let web else { return }
        switch action {
        case "increase", "decrease", "reset":
            if action == "reset" { model.value = 100 }
            else if action == "increase" { model.value = Self.zoomSteps.first { $0 > model.value } ?? 300 }
            else { model.value = Self.zoomSteps.last { $0 < model.value } ?? 50 }
            web.pageZoom = model.value / 100
        case "back": web.goBack()
        case "forward": web.goForward()
        case "reload": web.reload()
        case "toc":
            guard model.kind == .preview, model.hasHeadings else {
                throw NativeError.message("This preview has no headings")
            }
            model.tocOpen.toggle()
            web.callAsyncJavaScript("return portalToolbar.toc(open)", arguments: ["open": model.tocOpen],
                                    in: nil, in: Self.world, completionHandler: nil)
        default: throw NativeError.message("Unknown web toolbar action: \(action)")
        }
    }

    private func find(_ query: String, backwards: Bool) {
        // Serialize WebKit searches so rapid Return presses cannot desynchronize
        // the selected match and the readout. New text supersedes queued queries.
        if let last = searchQueue.last, last.0 != query { searchQueue.removeAll() }
        searchQueue.append((query, backwards))
        nextSearch()
    }

    private func finishSearch() {
        searching = false
        nextSearch()
    }

    private func nextSearch() {
        guard !searching, !searchQueue.isEmpty, let web else { return }
        searching = true
        let (query, backwards) = searchQueue.removeFirst()
        let request = generation
        let fresh = query != searched
        searched = query
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        // Count the rendered document in the same isolated world as the TOC.
        web.callAsyncJavaScript("return portalToolbar.count(query)", arguments: ["query": query],
                                in: nil, in: Self.world) { [weak self, weak web] result in
            guard let self else { return }
            guard let web, self.generation == request else { self.finishSearch(); return }
            let count = (try? result.get()) as? Int ?? 0
            web.find(query, configuration: config) { [weak self] found in
                guard let self else { return }
                defer { self.finishSearch() }
                guard self.generation == request else { return }
                self.model.matchCount = query.isEmpty || !found.matchFound ? 0 : max(1, count)
                if self.model.matchCount == 0 { self.model.matchIndex = 0 }
                else if fresh { self.model.matchIndex = backwards ? self.model.matchCount : 1 }
                else {
                    self.model.matchIndex = ((self.model.matchIndex - 1 + (backwards ? -1 : 1)
                                              + self.model.matchCount) % self.model.matchCount) + 1
                }
                self.model.changed?()
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let count = message.body as? Int else { return }
        model.hasHeadings = count > 0
        model.changed?()
    }

    private static let pageScript = #"""
    (() => {
      let panel;
      const headings = () => [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')]
        .filter(h => !panel?.contains(h));
      const report = () => window.webkit.messageHandlers.toolbar.postMessage(headings().length);
      globalThis.portalToolbar = {
        toc(open) {
          const items = headings();
          if (!panel) {
            panel = document.createElement('nav');
            panel.setAttribute('aria-label', 'Table of contents');
            panel.style.cssText = 'box-sizing:border-box;position:sticky;top:0;float:left;width: min(240px,35%);max-height:100vh;overflow:auto;padding:16px;font:13px/1.6 system-ui;background:Canvas;color:CanvasText;border-right:1px solid GrayText';
            document.body.prepend(panel);
          }
          panel.replaceChildren();
          for (const h of items) {
            const link = document.createElement('a');
            link.textContent = h.textContent;
            link.href = '#';
            link.style.cssText = `display:block;color:inherit;margin-left:${(Number(h.tagName[1])-1)*10}px`;
            link.onclick = event => { event.preventDefault(); h.scrollIntoView({block:'start',behavior:'smooth'}); };
            panel.append(link);
          }
          panel.hidden = !open || !items.length;
          return items.length;
        },
        count(query) {
          if (!query) return 0;
          const text = document.body.innerText.toLocaleLowerCase();
          const needle = query.toLocaleLowerCase();
          let count = 0, index = 0;
          while ((index = text.indexOf(needle, index)) !== -1) { count++; index += needle.length; }
          return count;
        }
      };
      let previous = -1;
      new MutationObserver(() => {
        const count = headings().length;
        if (count !== previous) { previous = count; report(); }
      }).observe(document.body, {childList:true, subtree:true});
      report();
    })();
    """#
}
