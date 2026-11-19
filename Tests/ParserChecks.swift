import Foundation

@main
struct ParserChecks {
    @MainActor static func main() throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: " + name) }
            passed += 1
            print("PASS: " + name)
        }
        let fb2 = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FictionBook xmlns:l="http://www.w3.org/1999/xlink">
        <description><title-info><book-title>Тест &amp; книга</book-title><author><first-name>Иван</first-name><last-name>Тестов</last-name></author></title-info></description>
        <body><section id="one"><title><p>Первая глава</p></title><p>Кириллица, English, ёж и эмодзи 😀.</p><p>Второй абзац.</p></section><section><title><p>Вторая глава</p></title><p>Финал.</p></section></body>
        <binary id="cover" content-type="image/png">QUJDREVGRw==</binary></FictionBook>
        """
        let book = try BookParser.parse(data: Data(fb2.utf8), fileName: "wrong.txt")
        check(book.format == "FB2", "Определение FB2 по содержимому")
        check(book.title == "Тест & книга", "XML-сущности")
        check(book.author == "Иван Тестов", "Автор FB2")
        check(!book.text.contains("QUJD") && !book.text.contains("Тестов"), "Исключены binary и метаданные")
        check(book.chapters.count == 2 && book.chapters[1].startOffset > 0, "Главы имеют реальные позиции")
        check((book.text as NSString).substring(from: book.chapters[1].startOffset).contains("Вторая"), "UTF-16 позиция после эмодзи")
        check(book.richHTML?.contains("data-offset") == true, "Разметка связана с текстом")
        check(book.richHTML?.contains("data-text-offset=") == true, "HTML содержит точные позиции текстовых фрагментов")
        let plain = try BookParser.parse(data: Data("Привет\nHello world".utf8), fileName: "test.txt")
        check(plain.chapters.isEmpty, "TXT без искусственного оглавления")
        let migrated = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book))
        check(migrated.text == book.text && migrated.settings == book.settings, "Сохранение и восстановление книги")
        for count in 0...100 {
            do { _ = try ZipArchive(data: Data(repeating: 0x50, count: count)); fatalError("Invalid ZIP accepted") } catch {}
        }
        check(true, "101 обрезанный/неверный архив отклонён без сбоя")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        func write(_ name: String, _ text: String) throws {
            let target = temp.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: target)
        }
        func zip(_ name: String, _ files: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = temp; process.arguments = ["-q", name] + files
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { fatalError("zip failed") }
            return try Data(contentsOf: temp.appendingPathComponent(name))
        }
        try write("book.fb2", fb2)
        let zipped = try BookParser.parse(data: zip("book.zip", ["book.fb2"]), fileName: "book.fb2.zip")
        check(zipped.text == book.text, "DEFLATE FB2.zip совпадает с FB2")
        try write("META-INF/container.xml", "<container><rootfiles><rootfile full-path='OPS/book.opf'/></rootfiles></container>")
        try write("OPS/book.opf", "<package xmlns:dc='urn:dc'><metadata><dc:title>EPUB test</dc:title><dc:creator>Автор</dc:creator></metadata><manifest><item href='b.xhtml' id='b'/><item id='a' href='a.xhtml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>")
        try write("OPS/a.xhtml", "<html><body><h1>Глава А</h1><p>Первый &amp; текст 😀.</p></body></html>")
        try write("OPS/b.xhtml", "<html><body><h1>Глава Б</h1><p>Последний текст.</p></body></html>")
        let epub = try BookParser.parse(data: zip("book.epub", ["META-INF/container.xml", "OPS/book.opf", "OPS/a.xhtml", "OPS/b.xhtml"]), fileName: "book.epub")
        check(epub.title == "EPUB test", "EPUB метаданные")
        check(epub.chapters.count == 2, "EPUB главы в порядке spine")
        check(epub.text.range(of: "Глава А")!.lowerBound < epub.text.range(of: "Глава Б")!.lowerBound, "Порядок атрибутов manifest не влияет на чтение")
        do { _ = try BookParser.parse(data: Data("<FictionBook><broken>".utf8), fileName: "bad.fb2"); fatalError("Invalid XML accepted") } catch {}
        check(true, "Повреждённый XML отклонён")
        try write("OPS/nav.xhtml", "<html xmlns:epub='urn:epub'><body><nav epub:type='toc'><ol><li><a href='a.xhtml'>Начало</a><ol><li><a href='b.xhtml'>Продолжение</a></li></ol></li></ol></nav></body></html>")
        try write("OPS/book.opf", "<package xmlns:dc='urn:dc'><metadata><dc:title>TOC</dc:title></metadata><manifest><item id='nav' href='nav.xhtml' properties='nav'/><item id='a' href='a.xhtml'/><item id='b' href='b.xhtml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>")
        let navBook = try BookParser.parse(data: zip("nav.epub", ["META-INF/container.xml", "OPS/book.opf", "OPS/a.xhtml", "OPS/b.xhtml", "OPS/nav.xhtml"]), fileName: "nav.epub")
        check(navBook.chapters.map(\.title) == ["Начало", "Продолжение"], "Авторское оглавление EPUB3")
        check(navBook.chapters[1].depth == 1, "Вложенность оглавления")
        check(navBook.generatedTOC == false, "Авторское оглавление не помечено сгенерированным")
        check(CRC32.checksum(Data("123456789".utf8)) == 0xcbf43926, "Контрольная сумма ZIP")
        var corrupt = try zip("crc.zip", ["book.fb2"])
        if let signature = corrupt.range(of: Data([0x50,0x4b,0x01,0x02])) { corrupt[signature.lowerBound + 16] ^= 1 }
        do { let archive = try ZipArchive(data: corrupt); _ = try archive.data(for: "book.fb2"); fatalError("CRC corruption accepted") } catch {}
        check(true, "Повреждённая CRC отклонена")
        let source = temp.appendingPathComponent("source.txt")
        try Data("Книга для проверки хранения".utf8).write(to: source)
        let store = LibraryStore(directory: temp.appendingPathComponent("library"))
        let first = try store.importBook(from: source)
        let duplicate = try store.importBook(from: source)
        check(first == duplicate && store.books.count == 1, "Повторный импорт открывает ту же книгу")
        var saved = store.books[0]
        saved.normalPosition = 7
        saved.position = 10
        saved.speedWPM = 425
        saved.bookmarks.append(Bookmark(id: UUID(), title: "Место", position: 7, createdAt: Date()))
        store.update(saved)
        let restored = LibraryStore(directory: temp.appendingPathComponent("library"))
        check(restored.books[0].normalPosition == 7 && restored.books[0].position == 10, "Два прогресса после перезапуска")
        check(restored.books[0].bookmarks.count == 1 && restored.books[0].speedWPM == 425, "Закладки и настройки после перезапуска")
        let fbSource = temp.appendingPathComponent("migrate.fb2")
        try Data(fb2.utf8).write(to: fbSource)
        let fbID = try restored.importBook(from: fbSource)
        var oldBook = restored.books.first(where: { $0.id == fbID })!
        oldBook.richHTML = "<p>Старый HTML без точных позиций</p>"
        oldBook.position = 20; oldBook.normalPosition = 10
        oldBook.bookmarks = [Bookmark(id: UUID(), title: "Сохранённая", position: 15, createdAt: Date())]
        restored.update(oldBook)
        let afterMigration = LibraryStore(directory: temp.appendingPathComponent("library")).books.first(where: { $0.id == fbID })!
        check(afterMigration.richHTML?.contains("data-text-offset=") == true, "Существующая книга обновляется без повторного импорта")
        check(afterMigration.position == 20 && afterMigration.normalPosition == 10 && afterMigration.bookmarks.count == 1, "Миграция HTML сохраняет прогресс и закладки")
        restored.remove(restored.books[0], deleteCopy: true)
        check(FileManager.default.fileExists(atPath: source.path), "Удаление не затрагивает исходник")
        check(!FileManager.default.fileExists(atPath: temp.appendingPathComponent("library").appendingPathComponent(saved.storedFile!).path), "Удалена только принадлежащая книге копия")
        let oldSettings = try JSONDecoder().decode(ReaderPreferences.self, from: Data("{}".utf8))
        check(oldSettings.orientation == "auto", "Миграция отсутствующих настроек")
        let imageXML = "<FictionBook xmlns:l='urn:xlink'><description><title-info><book-title>Иллюстрации</book-title><coverpage><image l:href='#cover'/></coverpage></title-info></description><body><section><p>Текст<a type='note' l:href='#n'>[1]</a></p><image l:href='#cover'/></section></body><body name='notes'><section id='n'><p>Сноска</p></section></body><binary id='cover' content-type='image/png'>iVBORw0KGgo=</binary></FictionBook>"
        let illustrated = try BookParser.parse(data: Data(imageXML.utf8), fileName: "image.fb2")
        check(illustrated.cover != nil && illustrated.richHTML?.contains("data:image/png;base64,") == true, "Обложка и встроенное изображение FB2")
        check(!illustrated.text.contains("Сноска") && !illustrated.text.contains("[1]"), "Сноски исключены из скорочтения")
        check(illustrated.richHTML?.contains("id=\"n\"") == true, "Сноска доступна в обычной читалке")
        if CommandLine.arguments.contains("--large") {
            let large = Data(repeating: 97, count: 100 * 1024 * 1024)
            let parsed = try BookParser.parse(data: large, fileName: "100mb.txt")
            check(parsed.text.utf8.count == large.count, "TXT 100 МБ импортирован без обрезки")
        }
        print("RESULT: \(passed) проверок пройдено")
    }
}
