import SwiftUI
import UIKit

@main
struct FaReAppApp: App {
    @UIApplicationDelegateAdaptor(ReaderAppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--self-test") { LayoutChecks.run() }
                    if ProcessInfo.processInfo.arguments.contains("--navigation-test") || ProcessInfo.processInfo.arguments.contains("--navigation-book-test") {
                        Task { @MainActor in await NavigationChecks.run() }
                    }
                    #endif
                }
        }
    }
}

final class ReaderAppDelegate: NSObject, UIApplicationDelegate {
    static var orientation: UIInterfaceOrientationMask = .allButUpsideDown
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { Self.orientation }
}

#if DEBUG
import UIKit
import WebKit

@MainActor
final class NavigationChecks: NSObject, WKNavigationDelegate {
    private static var hasRun = false
    private static var viewportMetrics: [String: Any] = [:]
    static func run() async {
        guard !hasRun else { return }
        hasRun = true
        write(["status":"running", "systemVersion":UIDevice.current.systemVersion])
        do {
            let longParagraph = (0..<1400).map { "слово\($0)" }.joined(separator: " ")
            let xml = "<FictionBook><body><section><p>Начало 😀 &amp; <strong>кириллица</strong> " + longParagraph + "</p></section></body></FictionBook>"
            let supplied = ProcessInfo.processInfo.arguments.contains("--navigation-book-test")
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("reproduction.fb2")
            let book = try BookParser.parse(data: supplied ? Data(contentsOf: url) : Data(xml.utf8), fileName: "reproduction.fb2")
            let offset = supplied ? ReadingTokens.make(book.text).first(where: { $0.offset >= (book.text as NSString).length / 3 })!.offset : (book.text as NSString).range(of: "слово900").location
            let cases = try await runHosted(book: book, offset: offset)
            write(["status":"passed", "cases":cases, "offset":offset,
                   "systemVersion":UIDevice.current.systemVersion, "viewport":viewportMetrics])
        } catch { write(["status":"failed", "error":String(describing: error), "viewport":viewportMetrics]) }
    }
    static func write(_ report: [String: Any]) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("navigation-checks.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }

    // Exercise the actual SwiftUI representable, including paging-enabled WKWebView,
    // modal dismissal and switching modes. An isolated JS call cannot catch these races.
    static func runHosted(book: Book, offset: Int) async throws -> [String] {
        guard let root = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.rootViewController else {
            throw NSError(domain: "No test window", code: 1)
        }
        let state = HandoffState(book)
        let host = UIHostingController(rootView: HandoffHarness(state: state))
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in root.present(host, animated: false) { continuation.resume() } }
        func webView(in view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        func visible(_ name: String, paged: Bool, target: Int? = nil) async throws {
            let target = target ?? offset
            var stableSince: Date?
            for _ in 0..<300 {
                if let web = webView(in: host.view),
                   let result = try? await web.evaluateJavaScript("""
                   (()=>{if(typeof readerTextRange!=='function'||readerNavigationID!=='\(state.navigationID.uuidString)')return false;
                   const range=readerTextRange(\(target));if(!range)return false;const r=range.getBoundingClientRect();
                   return r.left>=-1&&r.right<=innerWidth+1&&r.top>=-1&&r.bottom<=innerHeight+1
                     &&(getComputedStyle(document.body).columnCount==='1')===\(paged ? "true" : "false")})()
                   """) as? Bool, result {
                    if let stableSince, Date().timeIntervalSince(stableSince) >= 0.7 { return }
                    if stableSince == nil { stableSince = Date() }
                } else { stableSince = nil }
                try await Task.sleep(for: .milliseconds(25))
            }
            let web = webView(in: host.view)
            let metrics = try? await web?.evaluateJavaScript("JSON.stringify({x:scrollX,y:scrollY,w:innerWidth,h:innerHeight,contentWidth:document.scrollingElement.scrollWidth,rect:readerTextRange(\(target))?.getBoundingClientRect()})")
            throw NSError(domain: name, code: 1, userInfo: [NSLocalizedDescriptionKey:"\(name): target=\(target), model=\(state.book.normalPosition), native=\(String(describing:web?.scrollView.contentOffset)), size=\(String(describing:web?.scrollView.contentSize)), DOM=\(String(describing:metrics))"])
        }
        do {
            try await visible("Начальная страница перед скорочтением", paged: true, target: 0)
            let initialWeb = webView(in: host.view)
            if let initialWeb {
                viewportMetrics = (try? await initialWeb.evaluateJavaScript("""
                    ({before:window.readerViewportBefore||{},bodyHeight:getComputedStyle(document.body).height,
                      inlineHeight:document.body.style.height,columnFill:getComputedStyle(document.body).columnFill,
                      columnWidth:getComputedStyle(document.body).columnWidth,
                      columnCount:getComputedStyle(document.body).columnCount,width:innerWidth,height:innerHeight,
                      scrollWidth:document.scrollingElement.scrollWidth,scrollHeight:document.scrollingElement.scrollHeight})
                    """)) as? [String: Any] ?? [:]
                guard let horizontal = try? await initialWeb.evaluateJavaScript("document.scrollingElement.scrollWidth>innerWidth*2&&document.scrollingElement.scrollHeight<=innerHeight+2") as? Bool, horizontal else {
                    throw NSError(domain: "Страницы разложены вертикально вместо колонок", code: 1)
                }
            }
            state.suspended = true
            let speed = UIViewController()
            speed.modalPresentationStyle = .fullScreen
            await withCheckedContinuation { continuation in host.present(speed, animated: false) { continuation.resume() } }
            state.book.position = offset
            await withCheckedContinuation { continuation in speed.dismiss(animated: false) { continuation.resume() } }
            state.book.normalPosition = state.book.position
            state.navigationID = UUID()
            state.suspended = false
            try await visible("Страницы после закрытия скорочтения", paged: true)
            guard let initialWeb, webView(in: host.view) === initialWeb else {
                throw NSError(domain: "WebView пересоздан после скорочтения", code: 1)
            }
            state.book.settings.mode = "scroll"
            state.navigationID = UUID()
            try await visible("Прокрутка после Страниц", paged: false)
            state.book.settings.mode = "page"
            state.navigationID = UUID()
            try await visible("Страницы после Прокрутки", paged: true)
            guard let movingWeb = webView(in: host.view) else { throw NSError(domain: "No active WebView", code: 1) }
            movingWeb.scrollView.setContentOffset(CGPoint(x: movingWeb.bounds.width * 3, y: 0), animated: false)
            guard let captured = await state.bridge.capture?(), captured > 0, captured != offset else {
                throw NSError(domain: "Видимая позиция после реального смещения страницы", code: 1)
            }
            state.book.normalPosition = captured
            state.book.settings.mode = "scroll"
            state.navigationID = UUID()
            try await visible("Прокрутка после фактического перелистывания", paged: false, target: captured)
            guard let scrollingWeb = webView(in: host.view), scrollingWeb.scrollView.isScrollEnabled,
                  scrollingWeb.scrollView.panGestureRecognizer.isEnabled,
                  scrollingWeb.scrollView.contentSize.height > scrollingWeb.bounds.height * 2 else {
                throw NSError(domain: "Вертикальная область прокрутки", code: 1)
            }
            scrollingWeb.scrollView.setContentOffset(CGPoint(x: 0, y: scrollingWeb.bounds.height * 2), animated: false)
            guard let scrolled = await state.bridge.capture?(), scrolled > 0, scrolled != captured else {
                throw NSError(domain: "Позиция после вертикального смещения", code: 1)
            }
            state.book.normalPosition = scrolled
            state.book.settings.mode = "page"
            state.navigationID = UUID()
            try await visible("Страницы после фактической прокрутки", paged: true, target: scrolled)
            state.book.normalPosition = offset
            state.navigationID = UUID()
            try await visible("Возврат к исходному якорю", paged: true)
            state.immersive = true
            state.navigationID = UUID()
            try await visible("Полноэкранные Страницы", paged: true)
            state.book.normalFontSize = 32
            state.navigationID = UUID()
            try await visible("Страницы после изменения шрифта", paged: true)
            let end = (state.book.text as NSString).length - 1
            state.book.normalPosition = end
            state.navigationID = UUID()
            try await visible("Последний символ в Страницах", paged: true, target: end)
            state.book.settings.mode = "scroll"
            state.navigationID = UUID()
            try await visible("Последний символ в Прокрутке", paged: false, target: end)
            state.book.settings.mode = "page"
            state.book.normalPosition = 0
            state.navigationID = UUID()
            try await visible("Возврат на первую страницу", paged: true, target: 0)
            guard let web = webView(in: host.view) else { throw NSError(domain: "No WebView", code: 1) }
            func checkJS(_ script: String, _ name: String) async throws {
                for _ in 0..<80 {
                    if let value = try? await web.evaluateJavaScript(script) as? Bool, value { return }
                    try await Task.sleep(for: .milliseconds(25))
                }
                throw NSError(domain: name, code: 1)
            }
            try await checkJS("readerTapDirection(10,362)===-1&&readerTapDirection(181,362)===0&&readerTapDirection(350,362)===1", "Зоны экрана")
            _ = try await web.evaluateJavaScript("readerTurn(1)")
            try await checkJS("Math.abs(scrollX-innerWidth)<1", "Следующая страница")
            _ = try await web.evaluateJavaScript("readerTurn(-1)")
            try await checkJS("scrollX===0", "Предыдущая страница")
            _ = try await web.evaluateJavaScript("readerTurn(-1)")
            try await checkJS("scrollX===0", "Граница первой страницы")
            // A WebKit reply can arrive after SwiftUI has detached the old surface.
            // Hold that reply until detachment, then return the obsolete first-page offset.
            web.scrollView.setContentOffset(CGPoint(x: web.bounds.width * 2, y: 0), animated: false)
            _ = try await web.evaluateJavaScript("window.readerVisibleOffset=()=>new Promise(resolve=>window.releaseReaderCapture=()=>resolve(0));void 0")
            let staleCapture = Task { @MainActor in await state.bridge.capture?() }
            try await checkJS("typeof releaseReaderCapture==='function'", "Считывание позиции началось")
            state.mounted = false
            for _ in 0..<80 {
                if web.window == nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard web.window == nil else { throw NSError(domain: "Старая поверхность не удалена", code: 1) }
            state.book.normalPosition = offset
            _ = try await web.evaluateJavaScript("releaseReaderCapture()")
            _ = await staleCapture.value
            guard state.book.normalPosition == offset else {
                throw NSError(domain: "Запоздавшее считывание сбросило позицию на первую страницу", code: 1)
            }
            await withCheckedContinuation { continuation in host.dismiss(animated: false) { continuation.resume() } }
            return ["Реальная WKWebView: Страницы после закрытия скорочтения",
                    "Реальная WKWebView: Прокрутка после Страниц",
                    "Реальная WKWebView: Страницы после Прокрутки",
                    "Реальная WKWebView: полноэкранные Страницы",
                    "Реальная WKWebView: Страницы после изменения шрифта",
                    "Реальная WKWebView: возврат на первую страницу",
                    "Реальная WKWebView: зоны перелистывания",
                    "Реальная WKWebView: следующая страница",
                    "Реальная WKWebView: предыдущая страница",
                    "Реальная WKWebView: граница начала книги"]
                + ["Считывание позиции после нативного перелистывания",
                   "Прокрутка после фактического перелистывания",
                   "Страницы после фактической прокрутки",
                   "Вертикальная область прокрутки и считывание позиции",
                   "Поздний ответ удалённого WebView не сбрасывает позицию",
                   "Возврат из скорочтения сохраняет экземпляр WebView",
                   "Последний символ доступен в Страницах",
                   "Последний символ доступен в Прокрутке",
                   "Страницы формируют горизонтальные колонки фиксированной высоты"]
        } catch {
            await withCheckedContinuation { continuation in host.dismiss(animated: false) { continuation.resume() } }
            throw error
        }
    }
}

@MainActor
final class HandoffState: ObservableObject {
    @Published var book: Book
    @Published var navigationID = UUID()
    @Published var immersive = false
    @Published var mounted = true
    @Published var suspended = false
    let bridge = ReaderViewportBridge()
    init(_ book: Book) { self.book = book }
}
struct HandoffHarness: View {
    @ObservedObject var state: HandoffState
    var body: some View {
        if state.mounted {
            RichReadingSurface(html: state.book.richHTML!, book: $state.book, highlight: nil,
                               navigationID: state.navigationID, immersive: state.immersive, onRevealControls: {}, bridge: state.bridge, suspended: state.suspended)
                .id(state.book.settings.mode)
        }
    }
}

enum LayoutChecks {
    static func run() {
        let start = Date()
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks.append(name) }
        let text = String(repeating: "Русский English ёж 😀 e\u{301} — строка текста.\nВторой абзац.\n", count: 1800)
        for size in [CGSize(width: 320, height: 560), CGSize(width: 362, height: 640), CGSize(width: 700, height: 280)] {
            let attributed = PageLayoutEngine.attributed(text, fontSize: 20, spacing: 8, fontName: "Georgia")
            let ranges = PageLayoutEngine.ranges(attributed, size: size)
            check(!ranges.isEmpty, "Страницы рассчитаны \(size)")
            var expected = 0
            for range in ranges {
                check(range.location == expected && range.length > 0, "Страница без пропуска \(expected)")
                expected = NSMaxRange(range)
            }
            check(expected == attributed.length, "Весь Unicode-текст распределён \(size)")
        }
        let tokens = ReadingTokens.make("Слово-с-дефисом 12.5 https://example.org\nСледующий")
        check(tokens.count == 4, "Дефисы, десятичные числа, URL — один токен")
        check(tokens[3].paragraph == tokens[3].offset, "Возврат к началу абзаца")
        check(ReadingTapZones.direction(x: 10, width: 362) == -1 &&
              ReadingTapZones.direction(x: 181, width: 362) == 0 &&
              ReadingTapZones.direction(x: 350, width: 362) == 1, "Зоны перелистывания нативной читалки")
        let report: [String: Any] = ["status":"passed", "checks":checks.count, "elapsedSeconds":Date().timeIntervalSince(start), "cases":checks]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("layout-checks.json")
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
#endif
