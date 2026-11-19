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
                    if ProcessInfo.processInfo.arguments.contains("--navigation-test") { await NavigationChecks.run() }
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
    var loaded: CheckedContinuation<Void, Error>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded?.resume(throwing: error); loaded = nil }
    static func run() async {
        var cases: [String] = []
        let delegate = NavigationChecks()
        let view = WKWebView(frame: CGRect(x: -1000, y: 0, width: 362, height: 600))
        view.navigationDelegate = delegate
        let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
        window?.addSubview(view)
        defer { view.removeFromSuperview() }
        do {
            let longParagraph = (0..<1400).map { "слово\($0)" }.joined(separator: " ")
            let xml = "<FictionBook><body><section><p>Начало 😀 &amp; <strong>кириллица</strong> " + longParagraph + "</p></section></body></FictionBook>"
            let book = try BookParser.parse(data: Data(xml.utf8), fileName: "long.fb2")
            let offset = (book.text as NSString).range(of: "слово900").location
            let html = """
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
            html,body{margin:0;padding:0}body{width:100vw;height:100dvh;column-count:1;column-gap:0;column-fill:auto;font:20px/28px Georgia}p{margin:0}
            </style></head><body>\(book.richHTML!)<script>\(ReaderNavigation.script)</script></body></html>
            """
            try await withCheckedThrowingContinuation { continuation in
                delegate.loaded = continuation
                view.loadHTMLString(html, baseURL: nil)
            }
            func verify(_ expression: String, _ name: String) async throws {
                guard let passed = try await view.evaluateJavaScript(expression) as? Bool, passed else { throw NSError(domain: name, code: 1) }
                cases.append(name)
            }
            _ = try await view.evaluateJavaScript("jump(\(offset),'first-handoff')")
            try await verify("(()=>{const r=readerTextRange(\(offset)).getBoundingClientRect();return scrollX>innerWidth*5 && r.left>=-1 && r.right<=innerWidth+1})()", "Точное слово в длинном абзаце находится на видимой странице")
            _ = try await view.evaluateJavaScript("jump(0,'back');jump(\(offset),'repeat-handoff')")
            try await verify("(()=>{const r=readerTextRange(\(offset)).getBoundingClientRect();return r.left>=-1 && r.right<=innerWidth+1 && readerNavigationID==='repeat-handoff'})()", "Повторный выход скорочтения повторяет переход к слову")
            _ = try await view.evaluateJavaScript("document.body.style.fontSize='32px';jump(\(offset),'resized')")
            try await verify("(()=>{const r=readerTextRange(\(offset)).getBoundingClientRect();return r.left>=-1 && r.right<=innerWidth+1})()", "Переход после изменения размера шрифта")
            try await verify("readerTapDirection(10,362)===-1 && readerTapDirection(180,362)===0 && readerTapDirection(350,362)===1", "Зоны экрана: влево, управление, вправо")
            _ = try await view.evaluateJavaScript("jump(0,'tap-test');readerTurn(1)")
            try await verify("Math.abs(scrollX-innerWidth)<1", "Нажатие справа переходит ровно на следующую страницу")
            _ = try await view.evaluateJavaScript("readerTurn(-1)")
            try await verify("scrollX===0", "Нажатие слева возвращает страницу назад")
            _ = try await view.evaluateJavaScript("readerTurn(-1)")
            try await verify("scrollX===0", "Перелистывание не выходит за начало книги")
            _ = try await view.evaluateJavaScript("document.body.style.columnCount='auto';document.body.style.height='auto';jump(\(offset),'scroll-mode')")
            try await verify("(()=>{const r=readerTextRange(\(offset)).getBoundingClientRect();return scrollY>0 && r.top>=-1 && r.bottom<innerHeight})()", "Прокрутка к тому же слову")
            let report: [String: Any] = ["status":"passed", "cases":cases, "offset":offset]
            write(report)
        } catch { write(["status":"failed", "cases":cases, "error":String(describing: error)]) }
    }
    static func write(_ report: [String: Any]) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("navigation-checks.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
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
