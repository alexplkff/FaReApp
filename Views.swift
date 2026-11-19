import SwiftUI
import UniformTypeIdentifiers
import UIKit
import CoreText
import WebKit

enum ReaderNavigation {
    // UTF-16 offsets are shared by NSString, the tokenizer and DOM text nodes.
    static let script = """
    let programmatic=false;
    let readerNavigationID='';
    let readerImmersive=false;
    function readerTapDirection(x,width){return x<width*0.3?-1:x>width*0.7?1:0}
    function readerTurn(direction){
      const root=document.scrollingElement;
      if(getComputedStyle(document.body).columnCount==='1'){
        const page=Math.round(scrollX/innerWidth);
        const last=Math.max(0,Math.ceil(root.scrollWidth/innerWidth)-1);
        scrollTo(Math.min(last,Math.max(0,page+direction))*innerWidth,0);
      }else scrollBy(0,direction*innerHeight*0.9);
    }
    document.addEventListener('click',e=>{
      if(!readerImmersive)return;
      e.preventDefault();e.stopImmediatePropagation();
      const direction=readerTapDirection(e.clientX,innerWidth);
      if(direction===0)webkit.messageHandlers.position.postMessage({action:'reveal'});
      else readerTurn(direction);
    },true);
    function readerTextRange(offset) {
      const runs=[...document.querySelectorAll('[data-text-offset]')];
      let target=runs.find(n=>Number(n.dataset.textOffset)<=offset &&
          offset<Number(n.dataset.textOffset)+n.textContent.length);
      if(!target)target=runs.filter(n=>Number(n.dataset.textOffset)<=offset).pop() || runs[0];
      if(!target)return null;
      let remaining=Math.min(Math.max(0,offset-Number(target.dataset.textOffset)),Math.max(0,target.textContent.length-1));
      const walker=document.createTreeWalker(target,NodeFilter.SHOW_TEXT);
      let node;
      while(node=walker.nextNode()){
        if(remaining<node.length){
          const range=document.createRange();
          range.setStart(node,remaining);range.setEnd(node,Math.min(remaining+1,node.length));
          return range;
        }
        remaining-=node.length;
      }
      return null;
    }
    function jump(offset,navigationID=''){
      readerNavigationID=navigationID;
      const range=readerTextRange(offset);
      const paged=getComputedStyle(document.body).columnCount==='1';
      if(range){
        programmatic=true;
        const rect=range.getBoundingClientRect();
        if(paged)scrollTo(Math.floor((rect.left+scrollX+0.5)/innerWidth)*innerWidth,0);
        else scrollTo(0,Math.max(0,rect.top+scrollY-8));
        setTimeout(()=>programmatic=false,250);
        return {offset,page:Math.round(scrollX/innerWidth),found:true};
      }
      const target=[...document.querySelectorAll('[data-offset]')].filter(n=>Number(n.dataset.offset)<=offset).pop();
      if(target){programmatic=true;target.scrollIntoView({block:'start',inline:'start'});
        if(paged)scrollTo(Math.round(scrollX/innerWidth)*innerWidth,0);
        setTimeout(()=>programmatic=false,250);
      }
      return {offset,found:false};
    }
    """
}

enum ReadingTapZones {
    static func direction(x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return x < width * 0.3 ? -1 : x > width * 0.7 ? 1 : 0
    }
}

struct ContentsList: View {
    let chapters: [Chapter]
    let position: Int
    let onSelect: (Chapter) -> Void
    @State private var collapsed: Set<UUID> = []
    var visible: [Chapter] {
        var hiddenDepth: Int?
        return chapters.filter { chapter in
            let depth = chapter.depth ?? 0
            if let hidden = hiddenDepth, depth > hidden { return false }
            hiddenDepth = collapsed.contains(chapter.id) ? depth : nil
            return true
        }
    }
    var current: UUID? { chapters.last(where: { $0.startOffset <= position })?.id }
    var body: some View {
        List(visible) { chapter in
            HStack {
                Button { onSelect(chapter) } label: {
                    HStack {
                        Text(chapter.title).foregroundStyle(.primary)
                        Spacer()
                        if current == chapter.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                if let index = chapters.firstIndex(where: { $0.id == chapter.id }), index + 1 < chapters.count,
                   (chapters[index + 1].depth ?? 0) > (chapter.depth ?? 0) {
                    Button {
                        if collapsed.contains(chapter.id) { collapsed.remove(chapter.id) } else { collapsed.insert(chapter.id) }
                    } label: { Image(systemName: collapsed.contains(chapter.id) ? "chevron.right" : "chevron.down") }.buttonStyle(.borderless)
                }
            }.padding(.leading, CGFloat(chapter.depth ?? 0) * 16)
        }.overlay { if chapters.isEmpty { ContentUnavailableView("Оглавления нет", systemImage: "list.bullet") } }
    }
}

struct RichReadingSurface: UIViewRepresentable {
    let html: String
    @Binding var book: Book
    let highlight: NSRange?
    let navigationID: UUID
    let immersive: Bool
    let onRevealControls: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "position")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.scrollView.isPagingEnabled = book.settings.mode == "page"
        let key = "\(book.normalFontSize)-\(book.lineSpacing)-\(book.settings)-\(view.traitCollection.userInterfaceStyle.rawValue)-\(immersive)"
        if coordinator.key != key {
            coordinator.key = key
            coordinator.ready = false
            let dark = book.settings.theme == "dark" || (book.settings.theme == "system" && view.traitCollection.userInterfaceStyle == .dark)
            let color = dark ? "#eee" : "#181818"
            let bg = dark ? "#111" : book.settings.theme == "sepia" ? "#f7edd4" : "#fff"
            let columns = book.settings.mode == "page" ? "height:100dvh;width:100vw;column-count:1;column-gap:0;column-fill:auto;" : ""
            let scaledSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: book.normalFontSize)
            let document = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
            <style>
            *{box-sizing:border-box}html{background:\(bg);color:\(color);overflow-y:\(book.settings.mode == "page" ? "hidden" : "auto")}
            body{margin:0;padding:0;font-family:'\(book.settings.font)',-apple-system,'Apple Color Emoji',serif;font-size:\(scaledSize)px;line-height:\(scaledSize + book.lineSpacing)px;\(columns)}
            p{margin:0 0 0.6em}img{display:block;max-width:100%;max-height:75dvh;object-fit:contain;break-inside:avoid}h1,h2,h3{line-height:1.2;break-after:avoid}
            a{color:#1677cc}section{margin:0}blockquote{margin:1em}mark{background:#ffdf58;color:#111}
            </style></head><body>\(html)
            <script>
            let linkOrigin=null;
            document.addEventListener('click',e=>{
              const anchor=e.target.closest('a[href^="#"]');
              if(!anchor)return;
              const target=document.getElementById(decodeURIComponent(anchor.getAttribute('href').slice(1)));
              if(!target)return;
              e.preventDefault();
              linkOrigin={x:scrollX,y:scrollY};
              target.scrollIntoView();
              if(getComputedStyle(document.body).columnCount==='1')scrollTo(Math.round(scrollX/innerWidth)*innerWidth,0);
              let back=document.getElementById('fare-return');
              if(!back){
                back=document.createElement('button');back.id='fare-return';back.textContent='Вернуться к тексту';
                back.style='position:fixed;bottom:10px;right:10px;z-index:999;background:#1677cc;color:white;border:0;border-radius:12px;padding:12px';
                back.onclick=()=>{scrollTo(linkOrigin.x,linkOrigin.y);back.remove()};
                document.documentElement.append(back);
              }
            });
            if(\(book.settings.authorStyle ? "true" : "false")){
              document.querySelectorAll('style[data-author]').forEach(s=>s.media='all');
              document.querySelectorAll('[data-author-style]').forEach(n=>n.setAttribute('style',n.dataset.authorStyle));
            }
            \(ReaderNavigation.script)
            let timer;
            addEventListener('scroll',()=>{clearTimeout(timer);timer=setTimeout(()=>{
              if(programmatic)return;
              const node=document.elementFromPoint(12,24)?.closest('[data-offset]');
              if(node?.closest('.footnotes'))return;
              const root=document.scrollingElement;
              const paged=getComputedStyle(document.body).columnCount==='1';
              const ended=paged?scrollX+innerWidth>=root.scrollWidth-2:scrollY+innerHeight>=root.scrollHeight-2;
              let offset=node?Number(node.dataset.offset):null;
              const caret=document.caretRangeFromPoint(12,24);
              const span=caret?.startContainer.parentElement?.closest('[data-text-offset]');
              if(span){
                const prefix=document.createRange();prefix.selectNodeContents(span);
                prefix.setEnd(caret.startContainer,caret.startOffset);
                offset=Number(span.dataset.textOffset)+prefix.toString().length;
              }
              if(offset!==null)webkit.messageHandlers.position.postMessage({offset,ended,navigationID:readerNavigationID});
            },150)});
            </script></body></html>
            """
            view.loadHTMLString(document, baseURL: nil)
        } else { coordinator.navigate(view) }
        if coordinator.ready { view.evaluateJavaScript("readerImmersive=\(immersive ? "true" : "false")", completionHandler: nil) }
        coordinator.applyHighlight(view)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.configuration.userContentController.removeScriptMessageHandler(forName: "position") }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RichReadingSurface
        var key = ""
        var lastPosition = -1
        var lastHighlight: NSRange?
        var lastNavigationID: UUID?
        var ready = false
        init(_ parent: RichReadingSurface) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            webView.evaluateJavaScript("readerImmersive=\(parent.immersive ? "true" : "false")", completionHandler: nil)
            lastPosition = -1
            navigate(webView)
            lastHighlight = nil
            applyHighlight(webView)
        }
        func navigate(_ view: WKWebView) {
            guard ready, lastPosition != parent.book.normalPosition || lastNavigationID != parent.navigationID else { return }
            lastPosition = parent.book.normalPosition
            lastNavigationID = parent.navigationID
            view.evaluateJavaScript("jump(\(lastPosition), '\(parent.navigationID.uuidString)')", completionHandler: nil)
        }
        func applyHighlight(_ view: WKWebView) {
            guard let range = parent.highlight, range != lastHighlight, NSMaxRange(range) <= (parent.book.text as NSString).length else { return }
            lastHighlight = range
            let query = (parent.book.text as NSString).substring(with: range)
            guard let encoded = try? JSONEncoder().encode(query), let literal = String(data: encoded, encoding: .utf8) else { return }
            let script = """
            (()=>{const query=\(literal).toLowerCase();
            document.querySelectorAll('mark').forEach(m=>m.replaceWith(document.createTextNode(m.textContent)));
            const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
            let node;while(node=walker.nextNode()){
              if(['SCRIPT','STYLE'].includes(node.parentElement.tagName))continue;
              const start=node.textContent.toLowerCase().indexOf(query);if(start<0)continue;
              const range=document.createRange();range.setStart(node,start);range.setEnd(node,start+query.length);
              const mark=document.createElement('mark');range.surroundContents(mark);break;
            }})()
            """
            view.evaluateJavaScript(script, completionHandler: nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard ready else { return }
            if let command = message.body as? [String: Any], command["action"] as? String == "reveal" {
                parent.onRevealControls()
                return
            }
            if let offset = message.body as? Int { lastPosition = offset; parent.book.normalPosition = offset }
            if let data = message.body as? [String: Any], let offset = data["offset"] as? Int {
                guard data["navigationID"] as? String == parent.navigationID.uuidString else { return }
                lastPosition = offset; parent.book.normalPosition = offset
                if data["ended"] as? Bool == true { parent.book.isFinished = true }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                guard let url = navigationAction.request.url, !url.fragment.isNilOrEmpty else { decisionHandler(.cancel); return }
                if url.scheme == "http" || url.scheme == "https" { decisionHandler(.cancel); return }
            }
            decisionHandler(.allow)
        }
    }
}
private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showingImporter = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var sort = "recent"
    @State private var path: [UUID] = []
    @State private var pendingDelete: Book?
    @State private var largeFile: URL?
    @State private var importing = false

    private var visibleBooks: [Book] {
        let filtered = library.books.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) }
        return filtered.sorted {
            switch sort {
            case "title": return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case "author": return $0.author.localizedStandardCompare($1.author) == .orderedAscending
            default: return $0.lastOpened > $1.lastOpened
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if library.books.isEmpty {
            ContentUnavailableView("Библиотека пуста", systemImage: "books.vertical", description: Text("Импортируйте EPUB, FB2 или TXT через кнопку +"))
        } else {
            List {
                ForEach(visibleBooks) { book in
                    NavigationLink(value: book.id) { BookRow(book: book) }
                        .contextMenu {
                            Button("Убрать из библиотеки", role: .destructive) { pendingDelete = book }
                            Button("Удалить книгу с устройства", role: .destructive) { pendingDelete = book }
                        }
                }
                .onDelete { offsets in
                    if let first = offsets.first { pendingDelete = visibleBooks[first] }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var navigationContent: some View {
        libraryContent
            .navigationTitle("Моя библиотека")
            .searchable(text: $query, prompt: "Название или автор")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImporter = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Сортировка", systemImage: "arrow.up.arrow.down") {
                        Picker("Сортировка", selection: $sort) {
                            Text("Последнее открытие").tag("recent")
                            Text("Название").tag("title")
                            Text("Автор").tag("author")
                        }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let book = library.books.first(where: { $0.id == id }) { ReaderView(book: book) }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.plainText, .data, UTType(filenameExtension: "epub")!, UTType(filenameExtension: "fb2")!, UTType(filenameExtension: "zip")!]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 100 * 1024 * 1024 { largeFile = url }
                    else { importURL(url) }
                } catch { errorMessage = error.localizedDescription }
            }
            .alert("Не удалось импортировать книгу", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
                Button("OK") { errorMessage = nil }
            } message: { Text($0) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            navigationContent
        }
        .onOpenURL { url in importURL(url) }
        .overlay { if importing { ProgressView("Импорт книги…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .disabled(importing)
        .alert("Не удалось сохранить изменения", isPresented: Binding(get: { library.persistenceError != nil }, set: { if !$0 { library.persistenceError = nil } })) {
            Button("OK") { library.persistenceError = nil }
        } message: { Text(library.persistenceError ?? "") }
        .confirmationDialog("Удалить книгу и внутреннюю копию? Исходный файл останется в «Файлах».", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Удалить", role: .destructive) { if let book = pendingDelete { library.remove(book, deleteCopy: true) }; pendingDelete = nil }
        }
        .alert("Книга больше 100 МБ", isPresented: Binding(get: { largeFile != nil }, set: { if !$0 { largeFile = nil } })) {
            Button("Импортировать") { if let url = largeFile { importURL(url, allowLarge: true) }; largeFile = nil }
            Button("Отмена", role: .cancel) { largeFile = nil }
        } message: { Text("Обработка может занять больше времени.") }
    }
    func importURL(_ url: URL, allowLarge: Bool = false) {
        Task { @MainActor in
            importing = true
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() }; importing = false }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if !allowLarge && bytes > 100 * 1024 * 1024 { largeFile = url; return }
            do { path.append(try await library.importBookAsync(from: url)) } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct BookRow: View {
    let book: Book
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)).frame(width: 52, height: 70)
                .overlay {
                    if let data = book.cover, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 52, height: 70).clipped().clipShape(RoundedRectangle(cornerRadius: 8)) }
                    else { Image(systemName: "book.closed").foregroundStyle(.tint) }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                Text("\(book.format) · \(book.isFinished ? "Прочитано" : "\(Int(Double(book.normalPosition) / Double(max(1, (book.text as NSString).length)) * 100))%")").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}

struct ReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State var book: Book
    @State private var panel: String?
    @State private var speed = false
    @State private var highlighted: NSRange?
    @State private var finishedAlert = false
    @State private var readerNavigationID = UUID()
    @State private var immersive = false

    var body: some View {
        VStack(spacing: 0) {
            if !immersive {
            Picker("Режим", selection: $book.settings.mode) {
                Text("Страницы").tag("page"); Text("Прокрутка").tag("scroll")
            }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 6)
            }
            GeometryReader { geometry in
                let width = min(geometry.size.width - book.settings.margin * 2, geometry.size.width * book.settings.width / 100)
                Group {
                    if let html = book.richHTML {
                        RichReadingSurface(html: html, book: $book, highlight: highlighted, navigationID: readerNavigationID, immersive: immersive, onRevealControls: { immersive = false })
                    } else {
                        ReadingSurface(book: $book, size: CGSize(width: max(80, width), height: max(80, geometry.size.height - 24)), highlight: highlighted, immersive: immersive, onRevealControls: { immersive = false })
                            .id(readerNavigationID)
                    }
                }
                    .frame(width: max(80, width), height: max(80, geometry.size.height - 24))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !immersive {
            HStack {
                Button { speed = true } label: { Image(systemName: "play.circle.fill") }.accessibilityLabel("Скорочтение")
                Spacer()
                Button { immersive = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Полноэкранное чтение")
                Spacer()
                Button { panel = "search" } label: { Image(systemName: "magnifyingglass") }
                Spacer()
                Button { panel = "contents" } label: { Image(systemName: "list.bullet") }
                Spacer()
                Menu {
                    Button("Добавить закладку", systemImage: "bookmark.fill") { addBookmark() }
                    Button("Все закладки") { panel = "bookmarks" }
                    Button(book.isFinished ? "Отметить непрочитанной" : "Отметить прочитанной") { book.isFinished.toggle(); save() }
                } label: { Image(systemName: "bookmark") }
                Spacer()
                Button { panel = "settings" } label: { Image(systemName: "textformat.size") }
            }.font(.title3).padding()
            }
        }
        .background(background)
        .preferredColorScheme(book.settings.theme == "system" ? nil : (book.settings.theme == "dark" ? .dark : .light))
        .navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
        .toolbar(immersive ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden : .visible)
        .fullScreenCover(isPresented: $speed, onDismiss: {
            book.normalPosition = book.position
            readerNavigationID = UUID()
            save()
        }) {
            SpeedReadingView(book: $book, onSave: save)
        }
        .sheet(isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } })) {
            NavigationStack {
                Group {
                    switch panel {
                    case "contents":
                        VStack {
                            if book.generatedTOC == true { Text("Сформировано по заголовкам").font(.caption).foregroundStyle(.secondary) }
                            ContentsList(chapters: book.chapters, position: book.normalPosition) { jump($0.startOffset) }
                        }
                    case "search": BookSearchView(text: book.text) { range in highlighted = range; jump(range.location) }
                    case "bookmarks":
                        List {
                            ForEach(book.bookmarks) { mark in Button(mark.title) { jump(mark.position) } }
                            .onDelete { book.bookmarks.remove(atOffsets: $0); save() }
                        }
                    default: settings
                    }
                }
                .navigationTitle(panelTitle)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { save(); panel = nil } } }
            }.presentationDetents([.large])
        }
        .onAppear { book.lastOpened = Date(); save() }
        .onDisappear { save() }
        .onChange(of: scene) { _, value in if value != .active { save() } }
        .onChange(of: speed) { _, value in if value { book.position = book.normalPosition } }
        .onChange(of: book.isFinished) { _, value in if value { finishedAlert = true } }
        .alert("Книга дочитана", isPresented: $finishedAlert) {
            Button("Начать сначала") { book.normalPosition = 0; book.position = 0; book.isFinished = false; save() }
            Button("В библиотеку") { save(); dismiss() }
            Button("Продолжить просмотр", role: .cancel) {}
        }
    }

    var background: Color { book.settings.theme == "sepia" ? Color(red: 0.97, green: 0.93, blue: 0.83) : Color(uiColor: .systemBackground) }
    var panelTitle: String {
        switch panel { case "contents": return "Оглавление"; case "search": return "Поиск"; case "bookmarks": return "Закладки"; default: return "Оформление" }
    }
    var settings: some View {
        Form {
            Picker("Тема", selection: $book.settings.theme) {
                Text("Системная").tag("system"); Text("Светлая").tag("light"); Text("Тёмная").tag("dark"); Text("Сепия").tag("sepia")
            }
            Picker("Шрифт", selection: $book.settings.font) {
                Text("Georgia").tag("Georgia"); Text("Системный").tag("system"); Text("Times New Roman").tag("TimesNewRomanPSMT")
            }
            Toggle("Оформление книги", isOn: $book.settings.authorStyle)
            Picker("Ориентация", selection: $book.settings.orientation) {
                Text("Автоматически").tag("auto"); Text("Книжная").tag("portrait"); Text("Альбомная").tag("landscape")
            }.onChange(of: book.settings.orientation) { _, value in
                let mask: UIInterfaceOrientationMask = value == "portrait" ? .portrait : value == "landscape" ? .landscape : .allButUpsideDown
                ReaderAppDelegate.orientation = mask
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
                }
            }
            LabeledContent("Размер", value: "\(Int(book.normalFontSize))")
            Slider(value: $book.normalFontSize, in: 14...40, step: 1)
            LabeledContent("Интервал", value: "\(Int(book.lineSpacing))")
            Slider(value: $book.lineSpacing, in: 0...20, step: 1)
            LabeledContent("Поля", value: "\(Int(book.settings.margin))")
            Slider(value: $book.settings.margin, in: 8...48, step: 2)
            LabeledContent("Ширина текста", value: "\(Int(book.settings.width))%")
            Slider(value: $book.settings.width, in: 60...100, step: 5)
        }
    }
    func jump(_ offset: Int) { book.normalPosition = offset; book.position = offset; readerNavigationID = UUID(); panel = nil; save() }
    func save() { library.update(book) }
    func addBookmark() {
        let source = book.text as NSString
        let start = min(book.normalPosition, source.length)
        book.bookmarks.append(Bookmark(id: UUID(), title: source.substring(with: NSRange(location: start, length: min(100, source.length - start))), position: start, createdAt: Date()))
        save()
    }
}

struct BookSearchView: View {
    let text: String
    let onSelect: (NSRange) -> Void
    @State private var query = ""
    var results: [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var values: [NSRange] = []
        var offset = 0
        while offset < source.length && values.count < 200 {
            let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: offset, length: source.length - offset))
            if range.location == NSNotFound { break }
            values.append(range); offset = NSMaxRange(range)
        }
        return values
    }
    var body: some View {
        List(Array(results.enumerated()), id: \.offset) { _, range in
            Button {
                onSelect(range)
            } label: {
                let source = text as NSString
                let start = max(0, range.location - 35)
                Text(source.substring(with: NSRange(location: start, length: min(160, source.length - start)))).lineLimit(4)
            }
        }.searchable(text: $query, prompt: "Слово или фраза")
    }
}

enum PageLayoutEngine {
    static func attributed(_ text: String, fontSize: Double, spacing: Double, fontName: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = spacing
        style.paragraphSpacing = spacing
        let base = fontName == "system" ? UIFont.systemFont(ofSize: fontSize) : UIFont(name: fontName, size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        return NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: UIColor.label])
    }
    static func ranges(_ text: NSAttributedString, size: CGSize) -> [NSRange] {
        guard text.length > 0, size.width > 1, size.height > 1 else { return [] }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var result: [NSRange] = []
        var offset = 0
        while offset < text.length {
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
            let range = CTFrameGetVisibleStringRange(frame)
            guard range.length > 0 else { break }
            result.append(NSRange(location: offset, length: range.length))
            offset += range.length
        }
        return result
    }
}

struct ReadingSurface: View {
    @Binding var book: Book
    let size: CGSize
    let highlight: NSRange?
    let immersive: Bool
    let onRevealControls: () -> Void
    @State private var scrollTurn = 0
    @State private var ranges: [NSRange] = []
    @State private var selection = 0
    var attributed: NSAttributedString {
        let value = NSMutableAttributedString(attributedString: PageLayoutEngine.attributed(book.text, fontSize: book.normalFontSize, spacing: book.lineSpacing, fontName: book.settings.font))
        if let highlight, NSMaxRange(highlight) <= value.length { value.addAttribute(.backgroundColor, value: UIColor.systemYellow, range: highlight) }
        return value
    }
    var layoutKey: String { "\(size)-\(book.normalFontSize)-\(book.lineSpacing)-\(book.settings.font)" }
    var body: some View {
        Group {
            if book.settings.mode == "scroll" {
                ScrollingText(text: attributed, position: $book.normalPosition, turnRequest: scrollTurn)
            } else if ranges.isEmpty { ProgressView("Подготовка страниц…") }
            else {
                VStack(spacing: 4) {
                    TabView(selection: $selection) {
                        ForEach(ranges.indices, id: \.self) { index in
                            DrawnPage(text: attributed, range: ranges[index]).tag(index)
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .never))
                    if !immersive { Text("\(selection + 1) / \(ranges.count)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(SpatialTapGesture().onEnded { tap in
            guard immersive else { return }
            let direction = ReadingTapZones.direction(x: tap.location.x, width: size.width)
            if direction == 0 { onRevealControls() }
            else if book.settings.mode == "page" { selection = min(max(0, selection + direction), max(0, ranges.count - 1)) }
            else { scrollTurn += direction }
        })
        .task(id: layoutKey) {
            ranges = PageLayoutEngine.ranges(attributed, size: CGSize(width: size.width, height: max(1, size.height - 22)))
            selectPosition()
        }
        .onChange(of: book.normalPosition) { _, _ in selectPosition() }
        .onChange(of: selection) { _, value in
            if ranges.indices.contains(value), !NSLocationInRange(book.normalPosition, ranges[value]) {
                book.normalPosition = ranges[value].location
            }
            if ranges.count > 1 && value == ranges.count - 1 { book.isFinished = true }
        }
    }
    func selectPosition() {
        if let index = ranges.lastIndex(where: { $0.location <= book.normalPosition }), index != selection { selection = index }
    }
}

struct DrawnPage: UIViewRepresentable {
    let text: NSAttributedString
    let range: NSRange
    func makeUIView(context: Context) -> PageCanvas { PageCanvas() }
    func updateUIView(_ view: PageCanvas, context: Context) { view.text = text; view.range = range; view.setNeedsDisplay() }
}

final class PageCanvas: UIView {
    var text = NSAttributedString(string: "")
    var range = NSRange(location: 0, length: 0)
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isOpaque = false }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), text.length > 0 else { return }
        let mutable = NSMutableAttributedString(attributedString: text)
        mutable.addAttribute(.foregroundColor, value: UIColor.label.resolvedColor(with: traitCollection), range: NSRange(location: 0, length: text.length))
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(mutable), CFRange(location: range.location, length: range.length), CGPath(rect: bounds, transform: nil), nil)
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
    }
}

struct ScrollingText: UIViewRepresentable {
    let text: NSAttributedString
    @Binding var position: Int
    var turnRequest: Int = 0
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear; view.isEditable = false; view.isSelectable = false
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastTurn != turnRequest {
            let direction = turnRequest > context.coordinator.lastTurn ? 1.0 : -1.0
            context.coordinator.lastTurn = turnRequest
            let target = min(max(0, view.contentOffset.y + direction * view.bounds.height * 0.9), max(0, view.contentSize.height - view.bounds.height))
            view.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        }
        if !view.attributedText.isEqual(to: text) { view.attributedText = text }
        if abs(context.coordinator.lastPosition - position) > 1 {
            view.scrollRangeToVisible(NSRange(location: min(position, max(0, text.length - 1)), length: 1))
            context.coordinator.lastPosition = position
        }
    }
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: ScrollingText
        var lastPosition = -1
        var lastTurn = 0
        init(_ parent: ScrollingText) { self.parent = parent }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = scrollView as? UITextView, view.isDragging || view.isDecelerating else { return }
            let point = CGPoint(x: 1, y: view.contentOffset.y + 1)
            let glyph = view.layoutManager.glyphIndex(for: point, in: view.textContainer)
            let index = view.layoutManager.characterIndexForGlyph(at: glyph)
            lastPosition = index; parent.position = index
        }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard let view = scrollView as? UITextView, view.layoutManager.numberOfGlyphs > 0 else { return }
            let glyph = view.layoutManager.glyphIndex(for: CGPoint(x: 1, y: view.contentOffset.y + 1), in: view.textContainer)
            let index = view.layoutManager.characterIndexForGlyph(at: glyph)
            lastPosition = index; parent.position = index
        }
    }
}

struct ReadingToken {
    let word: String
    let offset: Int
    let paragraph: Int
}
enum ReadingTokens {
    static func make(_ text: String) -> [ReadingToken] {
        let source = text as NSString
        let regex = try! NSRegularExpression(pattern: #"\S+"#)
        var paragraph = 0
        var previous = 0
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            if source.substring(with: NSRange(location: previous, length: match.range.location - previous)).contains("\n") { paragraph = match.range.location }
            previous = NSMaxRange(match.range)
            let word = source.substring(with: match.range)
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return ReadingToken(word: word, offset: match.range.location, paragraph: paragraph)
        }
    }
}

struct SpeedReadingView: View {
    @Binding var book: Book
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var tokens: [ReadingToken] = []
    @State private var index = 0
    @State private var running = false
    @State private var contents = false
    @State private var chapterTitle: String?
    @State private var chapterStarts: [Int: String] = [:]
    @State private var editingSpeed = false
    @State private var speedInput = ""
    @State private var immersive = false
    var current: String { tokens.indices.contains(index) ? tokens[index].word : "Книга дочитана" }
    var body: some View {
        Group {
        if immersive {
            ZStack {
                Color(uiColor: .systemBackground)
                AnchoredWord(word: current, size: book.wordSize).frame(height: 150).padding(.horizontal, 20).allowsHitTesting(false)
                if let chapterTitle { VStack { Text(chapterTitle).font(.headline).padding(.top, 40); Spacer() }.allowsHitTesting(false) }
            }
            .contentShape(Rectangle())
            .onTapGesture { pause(); immersive = false }
            .accessibilityLabel("Полноэкранное скорочтение. Нажмите, чтобы остановить и показать управление.")
        } else {
        VStack(spacing: 16) {
            HStack {
                Button("Закрыть") { pause(); dismiss() }
                Spacer()
                Button { immersive = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Полноэкранное скорочтение")
                Spacer()
                Button { pause(); contents = true } label: { Image(systemName: "list.bullet") }
            }
            Spacer()
            if let chapterTitle { Text(chapterTitle).font(.headline) }
            AnchoredWord(word: current, size: book.wordSize).frame(height: 150).contentShape(Rectangle()).onTapGesture { toggle() }
            Spacer()
            Button("\(Int(book.speedWPM)) слов/мин") { pause(); speedInput = String(Int(book.speedWPM)); editingSpeed = true }.monospacedDigit()
            HStack {
                Button { book.speedWPM = max(50, book.speedWPM - 25) } label: { Image(systemName: "minus.circle") }
                Slider(value: $book.speedWPM, in: 50...1200, step: 25)
                Button { book.speedWPM = min(1200, book.speedWPM + 25) } label: { Image(systemName: "plus.circle") }
            }
            HStack { Text("Размер"); Slider(value: $book.wordSize, in: 24...96, step: 2) }
            HStack {
                Button { moveToParagraph() } label: { Image(systemName: "backward.end") }
                Spacer()
                Button { move(-1) } label: { Image(systemName: "backward.frame") }
                Spacer()
                Button { toggle() } label: { Label(running ? "Пауза" : "Читать", systemImage: running ? "pause.fill" : "play.fill") }
                Spacer()
                Button { move(1) } label: { Image(systemName: "forward.frame") }
            }.buttonStyle(.bordered)
            Text("\(min(index + 1, tokens.count)) / \(tokens.count)").font(.caption).foregroundStyle(.secondary)
            if index >= tokens.count && !tokens.isEmpty {
                Button("Начать сначала") { index = 0; book.isFinished = false; savePosition() }
            }
        }.padding(20)
        }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground))
        .statusBarHidden(immersive)
        .persistentSystemOverlays(immersive ? .hidden : .visible)
        .task {
            tokens = ReadingTokens.make(book.text)
            for chapter in book.chapters {
                if let start = tokens.firstIndex(where: { $0.offset >= chapter.startOffset }) { chapterStarts[start] = chapter.title }
            }
            index = tokens.firstIndex(where: { $0.offset >= book.position }) ?? tokens.count
        }
        .task(id: running) {
            guard running else { return }
            while running && tokens.indices.contains(index) {
                let token = tokens[index]
                if let title = chapterStarts[index], index > 0 {
                    chapterTitle = title
                    do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                    chapterTitle = nil
                }
                let last = token.word.last(where: { !"\"'»)]".contains($0) })
                let extra = last.map { ".!?…".contains($0) ? 0.35 : ",;:—".contains($0) ? 0.15 : 0 } ?? 0
                do { try await Task.sleep(for: .seconds(60 / book.speedWPM + extra)) } catch { return }
                guard running else { return }
                index += 1
            }
            if index >= tokens.count { book.isFinished = true }
            pause()
        }
        .onChange(of: scene) { _, phase in if phase != .active { pause() } }
        .onChange(of: running) { _, value in UIApplication.shared.isIdleTimerDisabled = value }
        .onDisappear { pause() }
        .alert("Скорость чтения", isPresented: $editingSpeed) {
            TextField("50–1200", text: $speedInput).keyboardType(.numberPad)
            Button("Применить") { if let value = Double(speedInput) { book.speedWPM = min(1200, max(50, value)); onSave() } }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(isPresented: $contents) {
            NavigationStack {
                ContentsList(chapters: book.chapters, position: book.position) { chapter in
                        index = tokens.firstIndex(where: { $0.offset >= chapter.startOffset }) ?? 0
                        contents = false; savePosition()
                }.navigationTitle("Оглавление")
            }
        }
    }
    func toggle() { if running { pause() } else if index < tokens.count { running = true } }
    func pause() { running = false; UIApplication.shared.isIdleTimerDisabled = false; savePosition() }
    func savePosition() {
        if tokens.indices.contains(index) { book.position = tokens[index].offset }
        else if !tokens.isEmpty { book.position = (book.text as NSString).length }
        onSave()
    }
    func move(_ step: Int) { pause(); index = min(max(0, index + step), max(0, tokens.count - 1)); savePosition() }
    func moveToParagraph() {
        pause()
        if tokens.indices.contains(index) {
            let offset = tokens[index].paragraph
            index = tokens.firstIndex(where: { $0.offset >= offset }) ?? 0
        }
        savePosition()
    }
}

struct AnchoredWord: View {
    let word: String
    let size: Double
    var body: some View {
        GeometryReader { geometry in
            let characters = Array(word)
            let letters = characters.indices.filter { characters[$0].isLetter || characters[$0].isNumber }
            let pivot = letters.isEmpty ? 0 : letters[(letters.count - 1) / 2]
            let before = String(characters.prefix(pivot))
            let center = characters.isEmpty ? "" : String(characters[pivot])
            let after = characters.isEmpty ? "" : String(characters.dropFirst(pivot + 1))
            let baseFont = UIFont(name: "Georgia", size: size)!
            let leftWidth = (before as NSString).size(withAttributes: [.font: baseFont]).width
            let centerWidth = (center as NSString).size(withAttributes: [.font: baseFont]).width
            let rightWidth = (after as NSString).size(withAttributes: [.font: baseFont]).width
            let scale = min(1, (geometry.size.width / 2 - 8) / max(1, max(leftWidth + centerWidth / 2, rightWidth + centerWidth / 2)))
            HStack(spacing: 0) {
                Text(before); Text(center).foregroundStyle(.red); Text(after)
            }.font(.custom("Georgia", size: size * scale)).fixedSize()
                .position(x: geometry.size.width / 2 + (rightWidth - leftWidth) * scale / 2, y: geometry.size.height / 2)
        }
    }
}
