import Foundation
import CryptoKit
import Combine

struct Book: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var author: String
    var fileName: String
    var format: String
    var text: String
    var chapters: [Chapter]
    var position: Int
    var isFinished: Bool
    var importedAt: Date
    var fingerprint: String
    var bookmarks: [Bookmark]
    var normalFontSize: Double
    var lineSpacing: Double
    var speedWPM: Double
    var wordSize: Double
    var normalPosition: Int = 0
    var lastOpened: Date = Date()
    var settings: ReaderPreferences = ReaderPreferences()
    var storedFile: String? = nil
    var richHTML: String? = nil
    var cover: Data? = nil
    var generatedTOC: Bool? = nil

    var words: [String] {
        TextTokenizer.tokens(from: text)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, fileName, format, text, chapters, position, isFinished, importedAt, fingerprint, bookmarks, normalFontSize, lineSpacing, speedWPM, wordSize, normalPosition, lastOpened, settings, storedFile, richHTML, cover, generatedTOC
    }

    init(id: UUID, title: String, author: String, fileName: String, format: String, text: String, chapters: [Chapter], position: Int, isFinished: Bool, importedAt: Date, fingerprint: String, bookmarks: [Bookmark] = [], normalFontSize: Double = 20, lineSpacing: Double = 8, speedWPM: Double = 300, wordSize: Double = 52) {
        self.id = id; self.title = title; self.author = author; self.fileName = fileName; self.format = format; self.text = text; self.chapters = chapters; self.position = position; self.isFinished = isFinished; self.importedAt = importedAt; self.fingerprint = fingerprint; self.bookmarks = bookmarks; self.normalFontSize = normalFontSize; self.lineSpacing = lineSpacing; self.speedWPM = speedWPM; self.wordSize = wordSize
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            author: try c.decode(String.self, forKey: .author),
            fileName: try c.decode(String.self, forKey: .fileName),
            format: try c.decode(String.self, forKey: .format),
            text: try c.decode(String.self, forKey: .text),
            chapters: try c.decode([Chapter].self, forKey: .chapters),
            position: try c.decodeIfPresent(Int.self, forKey: .position) ?? 0,
            isFinished: try c.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false,
            importedAt: try c.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date(),
            fingerprint: try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? "",
            bookmarks: try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? [],
            normalFontSize: try c.decodeIfPresent(Double.self, forKey: .normalFontSize) ?? 20,
            lineSpacing: try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 8,
            speedWPM: try c.decodeIfPresent(Double.self, forKey: .speedWPM) ?? 300,
            wordSize: try c.decodeIfPresent(Double.self, forKey: .wordSize) ?? 52
        )
        normalPosition = try c.decodeIfPresent(Int.self, forKey: .normalPosition) ?? 0
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened) ?? importedAt
        settings = try c.decodeIfPresent(ReaderPreferences.self, forKey: .settings) ?? ReaderPreferences()
        storedFile = try c.decodeIfPresent(String.self, forKey: .storedFile)
        richHTML = try c.decodeIfPresent(String.self, forKey: .richHTML)
        cover = try c.decodeIfPresent(Data.self, forKey: .cover)
        generatedTOC = try c.decodeIfPresent(Bool.self, forKey: .generatedTOC)
    }
}

struct Chapter: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var startOffset: Int
    var depth: Int? = nil
}

struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var position: Int
    var createdAt: Date
}

struct ReaderPreferences: Codable, Equatable {
    var theme = "system"
    var font = "Georgia"
    var margin: Double = 20
    var width: Double = 100
    var mode = "page"
    var authorStyle: Bool = false
    var orientation: String = "auto"
    init() {}
    enum CodingKeys: String, CodingKey { case theme, font, margin, width, mode, authorStyle, orientation }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? "Georgia"
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 20
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 100
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "page"
        authorStyle = try c.decodeIfPresent(Bool.self, forKey: .authorStyle) ?? false
        orientation = try c.decodeIfPresent(String.self, forKey: .orientation) ?? "auto"
    }
}

enum ReadingMode: String, CaseIterable, Identifiable {
    case page
    case scroll
    var id: String { rawValue }
    var title: String { self == .page ? "Страницы" : "Прокрутка" }
}

enum TextTokenizer {
    static func tokens(from text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    private let fileManager = FileManager.default
    private let key = "fareapp.books"
    private let customStorage: URL?

    init(directory: URL? = nil) {
        customStorage = directory
        load()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reproduction-demo"), books.isEmpty {
            let url = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("reproduction.fb2")
            _ = try? importBook(from: url)
        }
        if (ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--interaction-demo")), books.isEmpty {
            let paragraphs = (1...300).map { "<p>Абзац \($0). Когда читаешь книгу, слова складываются в историю. Кириллица и Latin, ёж и эмодзи 😀. Следующая строка помогает проверить сохранение позиции.</p>" }.joined()
            let xml = "<FictionBook><description><title-info><book-title>Проверка читалки</book-title></title-info></description><body><section><title><p>Первая глава</p></title>" + paragraphs + "</section><section><title><p>Вторая глава</p></title><p>Последняя страница книги.</p></section></body></FictionBook>"
            if let book = try? BookParser.parse(data: Data(xml.utf8), fileName: "demo.fb2") {
                _ = try? persistImport(data: Data(xml.utf8), parsed: book)
            }
        }
        #endif
    }

    var storageURL: URL {
        customStorage ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--reproduction-demo") ? "FaReApp-Reproduction-QA" : ProcessInfo.processInfo.arguments.contains("--interaction-demo") ? "FaReApp-Interaction-QA" : ProcessInfo.processInfo.arguments.contains("--demo") ? "FaReApp-QA" : "FaReApp", isDirectory: true)
    }

    @discardableResult
    func importBook(from url: URL) throws -> UUID {
        let data = try Data(contentsOf: url)
        let parsed = try BookParser.parse(data: data, fileName: url.lastPathComponent)
        return try persistImport(data: data, parsed: parsed)
    }

    func importBookAsync(from url: URL) async throws -> UUID {
        let result = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return (data, try BookParser.parse(data: data, fileName: url.lastPathComponent))
        }.value
        return try persistImport(data: result.0, parsed: result.1)
    }

    private func persistImport(data: Data, parsed: Book) throws -> UUID {
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = books.first(where: { $0.fingerprint == fingerprint }) {
            return existing.id
        }
        try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let destination = storageURL.appendingPathComponent("\(parsed.id.uuidString).source")
        try data.write(to: destination, options: .atomic)
        var imported = parsed
        imported.fingerprint = fingerprint
        imported.storedFile = destination.lastPathComponent
        books.append(imported)
        save()
        if let error = persistenceError {
            books.removeAll { $0.id == imported.id }
            try? fileManager.removeItem(at: destination)
            throw BookParserError.unsupported("Не удалось сохранить книгу: " + error)
        }
        return imported.id
    }

    func update(_ book: Book) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        save()
    }

    func addBookmark(to book: inout Book, title: String, position: Int) {
        book.bookmarks.append(Bookmark(id: UUID(), title: title, position: position, createdAt: Date()))
        update(book)
    }

    func removeBookmark(from book: inout Book, id: UUID) {
        book.bookmarks.removeAll { $0.id == id }
        update(book)
    }

    func remove(_ book: Book, deleteCopy: Bool) {
        books.removeAll { $0.id == book.id }
        if let file = book.storedFile {
            try? fileManager.removeItem(at: storageURL.appendingPathComponent(file))
        }
        save()
    }

    private func save() {
        persistenceError = nil
        guard let data = try? JSONEncoder().encode(books) else { return }
        do {
            try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
            try data.write(to: storageURL.appendingPathComponent("library.json"), options: .atomic)
        } catch { persistenceError = error.localizedDescription }
    }

    private func load() {
        guard let data = (try? Data(contentsOf: storageURL.appendingPathComponent("library.json"))) ?? UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Book].self, from: data) else { return }
        books = decoded
        // Earlier prototypes stored word indexes and unparsed XML as text.
        // Reparse the source copy once, preserving identity and the user's metadata.
        let files = (try? fileManager.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil)) ?? []
        var migrated = false
        for index in books.indices where books[index].storedFile == nil || (books[index].richHTML != nil && !(books[index].richHTML?.contains("data-text-offset=") ?? false)) {
            let candidates = books[index].storedFile.map { [storageURL.appendingPathComponent($0)] } ?? files.filter { $0.lastPathComponent.hasSuffix("-" + books[index].fileName) }
            guard candidates.count == 1, let source = candidates.first,
                  let data = try? Data(contentsOf: source),
                  let parsed = try? BookParser.parse(data: data, fileName: books[index].fileName) else { continue }
            let legacyTextChanged = books[index].text != parsed.text
            books[index].text = parsed.text
            books[index].chapters = parsed.chapters
            books[index].richHTML = parsed.richHTML
            books[index].cover = parsed.cover
            if legacyTextChanged {
                books[index].position = 0
                books[index].normalPosition = 0
            }
            books[index].storedFile = source.lastPathComponent
            migrated = true
        }
        if migrated { save() }
    }
    @Published var persistenceError: String?
}

enum BookParser {
    static func parse(data: Data, fileName: String) throws -> Book {
        if data.starts(with: [0x50, 0x4b]) {
            let archive = try ZipArchive(data: data)
            if archive.names.contains("META-INF/container.xml") { return try epub(archive, fileName: fileName) }
            let files = archive.names.filter { $0.lowercased().hasSuffix(".fb2") }
            guard files.count == 1 else { throw BookParserError.unsupported("Архив должен содержать одну книгу FB2") }
            var book = try fb2(archive.data(for: files[0]), fileName: fileName)
            book.format = "FB2.ZIP"
            return book
        }
        if let root = try? XMLNode.read(data), root.name == "FictionBook" { return try fb2(data, fileName: fileName) }
        guard (fileName as NSString).pathExtension.lowercased() == "txt" else {
            throw BookParserError.unsupported("Содержимое файла не соответствует TXT, FB2 или EPUB")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .windowsCP1251),
              !text.contains("\0"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BookParserError.empty }
        return make(fileName: fileName, title: (fileName as NSString).deletingPathExtension, author: "Неизвестный автор", format: "TXT", text: text, chapters: [])
    }

    private static func make(fileName: String, title: String, author: String, format: String, text: String, chapters: [Chapter]) -> Book {
        Book(id: UUID(), title: title, author: author, fileName: fileName, format: format, text: text, chapters: chapters, position: 0, isFinished: false, importedAt: Date(), fingerprint: "")
    }

    private static func fb2(_ data: Data, fileName: String) throws -> Book {
        let root = try XMLNode.read(data)
        guard root.name == "FictionBook" else { throw BookParserError.empty }
        let info = root.descendants("title-info").first
        let title = info?.descendants("book-title").first?.text ?? (fileName as NSString).deletingPathExtension
        let authorNode = info?.descendants("author").first
        let author = ["first-name", "middle-name", "last-name"].compactMap { authorNode?.descendants($0).first?.text }.joined(separator: " ")
        let bodies = root.children.filter { $0.name == "body" && !["notes", "comments"].contains($0.attributes["name"] ?? "") }
        let builder = TextBuilder()
        for body in bodies { builder.append(body) }
        guard !builder.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BookParserError.empty }
        var book = make(fileName: fileName, title: title, author: author.isEmpty ? "Неизвестный автор" : author, format: "FB2", text: builder.text, chapters: builder.chapters)
        var images: [String: String] = [:]
        for node in root.descendants("binary") {
            guard let id = node.attributes["id"], let data = Data(base64Encoded: node.text, options: .ignoreUnknownCharacters) else { continue }
            guard images[id] == nil else { throw BookParserError.unsupported("В FB2 повторяется идентификатор изображения") }
            images[id] = "data:" + (node.attributes["content-type"] ?? "image/jpeg") + ";base64," + data.base64EncodedString()
        }
        book.richHTML = bodies.map { builder.html($0, images: images) }.joined()
        let notes = root.children.filter { $0.name == "body" && ["notes", "comments"].contains($0.attributes["name"] ?? "") }
        book.richHTML? += notes.map { "<aside class=\"footnotes\">" + builder.html($0, images: images) + "</aside>" }.joined()
        if let href = info?.descendants("coverpage").first?.descendants("image").first?.attributes["l:href"] ?? info?.descendants("coverpage").first?.descendants("image").first?.attributes["xlink:href"],
           let value = images[String(href.dropFirst())], let payload = value.components(separatedBy: ",").last { book.cover = Data(base64Encoded: payload) }
        return book
    }

    private static func epub(_ archive: ZipArchive, fileName: String) throws -> Book {
        let container = try XMLNode.read(archive.data(for: "META-INF/container.xml"))
        guard let path = container.descendants("rootfile").first?.attributes["full-path"] else { throw BookParserError.unsupported("В EPUB отсутствует описание книги") }
        let package = try XMLNode.read(archive.data(for: path))
        if package.descendants("meta").contains(where: { $0.attributes["property"] == "rendition:layout" && $0.text == "pre-paginated" }) {
            throw BookParserError.unsupported("EPUB с фиксированной вёрсткой не поддерживается")
        }
        let items = package.descendants("item")
        let builder = TextBuilder()
        var htmlSections: [String] = []
        var cover: Data?
        var targets: [String: Int] = [:]
        let base = (path as NSString).deletingLastPathComponent
        for ref in package.descendants("itemref") where ref.attributes["linear"] != "no" {
            guard let item = items.first(where: { $0.attributes["id"] == ref.attributes["idref"] }), let href = item.attributes["href"] else {
                throw BookParserError.unsupported("Повреждён порядок глав EPUB")
            }
            let name = ((base.isEmpty ? "" : base + "/") + (href.removingPercentEncoding ?? href)) as NSString
            let document = try XMLNode.read(archive.data(for: name.standardizingPath))
            guard let body = document.descendants("body").first else { continue }
            builder.append(body)
            targets[name.standardizingPath] = builder.offsets[ObjectIdentifier(body)] ?? 0
            func recordTargets(_ node: XMLNode) {
                if let id = node.attributes["id"] { targets[name.standardizingPath + "#" + id] = builder.offsets[ObjectIdentifier(node)] ?? 0 }
                node.children.forEach(recordTargets)
            }
            recordTargets(body)
            var images: [String: String] = [:]
            for image in body.descendants("img") {
                guard let src = image.attributes["src"] else { continue }
                let dir = (name.standardizingPath as NSString).deletingLastPathComponent
                let imageName = ((dir + "/" + (src.removingPercentEncoding ?? src)) as NSString).standardizingPath
                let imageData = try archive.data(for: imageName)
                let ext = (imageName as NSString).pathExtension.lowercased()
                let mime = ext == "png" ? "image/png" : ext == "svg" ? "image/svg+xml" : "image/jpeg"
                images[src] = "data:" + mime + ";base64," + imageData.base64EncodedString()
                if cover == nil { cover = imageData }
            }
            htmlSections.append(builder.html(body, images: images))
        }
        guard !builder.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BookParserError.empty }
        var book = make(fileName: fileName, title: package.descendants("title").first?.text ?? (fileName as NSString).deletingPathExtension,
                    author: package.descendants("creator").first?.text ?? "Неизвестный автор",
                    format: "EPUB", text: builder.text, chapters: builder.chapters)
        book.richHTML = htmlSections.joined()
        for item in items where item.attributes["media-type"] == "text/css" {
            if let href = item.attributes["href"] {
                let name = (((base.isEmpty ? "" : base + "/") + href) as NSString).standardizingPath
                if let css = try? String(data: archive.data(for: name), encoding: .utf8) {
                    book.richHTML? += "<style data-author media=\"not all\">" + css.replacingOccurrences(of: "<", with: "") + "</style>"
                }
            }
        }
        var toc: [Chapter] = []
        if let nav = items.first(where: { ($0.attributes["properties"] ?? "").split(separator: " ").contains("nav") }),
           let href = nav.attributes["href"] {
            let navPath = (((base.isEmpty ? "" : base + "/") + href) as NSString).standardizingPath
            let document = try XMLNode.read(archive.data(for: navPath))
            let navNode = document.descendants("nav").first(where: { ($0.attributes["epub:type"] ?? "").contains("toc") }) ?? document.descendants("nav").first
            func walk(_ node: XMLNode, _ depth: Int) {
                if node.name == "a", let href = node.attributes["href"] {
                    let dir = (navPath as NSString).deletingLastPathComponent
                    let parts = (href.removingPercentEncoding ?? href).components(separatedBy: "#")
                    let file = parts[0].isEmpty ? navPath : ((dir + "/" + parts[0]) as NSString).standardizingPath
                    let key = file + (parts.count > 1 ? "#" + parts[1] : "")
                    if let offset = targets[key] ?? targets[file] { toc.append(Chapter(id: UUID(), title: node.text, startOffset: offset, depth: max(0, depth - 1))) }
                }
                node.children.forEach { walk($0, depth + ($0.name == "ol" ? 1 : 0)) }
            }
            if let navNode { walk(navNode, 0) }
        } else if let ncx = items.first(where: { $0.attributes["media-type"] == "application/x-dtbncx+xml" }), let href = ncx.attributes["href"] {
            let ncxPath = (((base.isEmpty ? "" : base + "/") + href) as NSString).standardizingPath
            let document = try XMLNode.read(archive.data(for: ncxPath))
            func walk(_ node: XMLNode, _ depth: Int) {
                if node.name == "navPoint", let src = node.children.first(where: { $0.name == "content" })?.attributes["src"] {
                    let key = ((((ncxPath as NSString).deletingLastPathComponent + "/" + src) as NSString).standardizingPath)
                    if let offset = targets[key] ?? targets[key.components(separatedBy: "#")[0]] {
                        toc.append(Chapter(id: UUID(), title: node.children.first(where: { $0.name == "navLabel" })?.text ?? "Раздел", startOffset: offset, depth: depth))
                    }
                }
                node.children.forEach { walk($0, depth + (node.name == "navPoint" ? 1 : 0)) }
            }
            walk(document, 0)
        }
        if !toc.isEmpty { book.chapters = toc; book.generatedTOC = false }
        else { book.generatedTOC = true }
        book.cover = cover
        return book
    }
}

final class XMLNode: NSObject, XMLParserDelegate {
    var name = ""
    var attributes: [String: String] = [:]
    var children: [XMLNode] = []
    var content: [Any] = []
    var text: String { content.map { ($0 as? String) ?? ($0 as? XMLNode)?.text ?? "" }.joined().trimmingCharacters(in: .whitespacesAndNewlines) }
    private var stack: [XMLNode] = []
    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    static func read(_ data: Data) throws -> XMLNode {
        let delegate = XMLNode()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.children.first else {
            throw BookParserError.unsupported("Повреждён XML книги: " + (parser.parserError?.localizedDescription ?? "нет корневого элемента"))
        }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = XMLNode()
        node.name = elementName.components(separatedBy: ":").last ?? elementName
        node.attributes = attributeDict
        let parent = stack.last ?? self
        parent.children.append(node); parent.content.append(node); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.content.append(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.content.append(String(decoding: CDATABlock, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
}

final class TextBuilder {
    var text = ""
    var chapters: [Chapter] = []
    var offsets: [ObjectIdentifier: Int] = [:]
    var textOffsets: [ObjectIdentifier: [Int: Int]] = [:]
    var sectionDepth = 0
    func append(_ node: XMLNode) {
        guard !["script", "style", "head", "binary", "description"].contains(node.name) else { return }
        if node.name == "a", node.attributes["type"] == "note" || node.attributes["epub:type"] == "noteref" { return }
        offsets[ObjectIdentifier(node)] = (text as NSString).length
        if node.name == "section" { sectionDepth += 1 }
        defer { if node.name == "section" { sectionDepth -= 1 } }
        if ["title", "h1", "h2", "h3", "h4"].contains(node.name) {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            chapters.append(Chapter(id: UUID(), title: node.text, startOffset: (text as NSString).length, depth: max(0, sectionDepth - 1)))
        }
        for (index, item) in node.content.enumerated() {
            if let value = item as? String {
                textOffsets[ObjectIdentifier(node), default: [:]][index] = (text as NSString).length
                text += value.replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
            }
            else if let child = item as? XMLNode { append(child) }
        }
        if ["p", "v", "title", "h1", "h2", "h3", "h4", "section", "div", "li", "br"].contains(node.name) { text += "\n" }
    }
    func html(_ node: XMLNode, images: [String: String]) -> String {
        if ["script", "style", "head", "binary", "description"].contains(node.name) { return "" }
        let offset = offsets[ObjectIdentifier(node)] ?? 0
        let id = node.attributes["id"].map { " id=\"" + $0.htmlEscaped + "\"" } ?? ""
        if ["img", "image"].contains(node.name) {
            let src = node.attributes["src"] ?? node.attributes["l:href"] ?? node.attributes["xlink:href"] ?? ""
            guard let value = images[src] ?? images[String(src.dropFirst())] else { return "" }
            return "<img data-offset=\"\(offset)\" src=\"" + value + "\" alt=\"\"/>"
        }
        let tags = ["body":"section", "section":"section", "title":"h2", "subtitle":"h3", "p":"p", "v":"p", "poem":"blockquote", "cite":"blockquote", "epigraph":"blockquote", "strong":"strong", "emphasis":"em", "a":"a"]
        let safe = ["div","span","h1","h2","h3","h4","h5","h6","ul","ol","li","blockquote","em","b","i","sup","sub","table","tr","td","th","br"]
        let tag = tags[node.name] ?? (safe.contains(node.name) ? node.name : "span")
        var href = ""
        if tag == "a", let link = node.attributes["href"] ?? node.attributes["l:href"] ?? node.attributes["xlink:href"],
           !link.contains("://") { href = " href=\"#" + (link.components(separatedBy: "#").last ?? link).htmlEscaped + "\"" }
        let inner = node.content.enumerated().map { index, item -> String in
            if let value = item as? String {
                guard let start = textOffsets[ObjectIdentifier(node)]?[index] else { return value.htmlEscaped }
                let normalized = value.replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
                return "<span data-text-offset=\"\(start)\">" + normalized.htmlEscaped + "</span>"
            }
            if let child = item as? XMLNode { return html(child, images: images) }
            return ""
        }.joined()
        let style = node.attributes["style"].map { " data-author-style=\"" + $0.htmlEscaped + "\"" } ?? ""
        let cls = node.attributes["class"].map { " class=\"" + $0.htmlEscaped + "\"" } ?? ""
        return "<\(tag) data-offset=\"\(offset)\"\(id)\(href)\(style)\(cls)>\(inner)</\(tag)>"
    }
}

extension String {
    var htmlEscaped: String { replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
}

enum BookParserError: LocalizedError {
    case unsupported(String), empty
    var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        case .empty: return "В книге не найден текст"
        }
    }
}
