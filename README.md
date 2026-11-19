# FaReApp

Локальная SwiftUI-читалка TXT, FB2, FB2.zip и адаптивных EPUB 2/3 для iPhone с iOS 26.

## Запуск

Откройте `FaReApp.xcodeproj` в Xcode 26.3. Для сборки без подписи:

```sh
xcodebuild -project FaReApp.xcodeproj -scheme FaReApp -sdk iphoneos \
  -configuration Debug -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO build
```

## Возможности

- импорт через «Файлы» и открытие URL документов; определение формата по содержимому;
- библиотека, обложки, поиск, сортировка, дубликаты по SHA-256;
- XML-разбор FB2 и EPUB, ZIP DEFLATE, CRC и проверка границ архивов;
- авторское EPUB3 NAV / EPUB2 NCX или оглавление из заголовков;
- страницы и прокрутка, поиск с переходом, закладки;
- встроенные изображения, внутренние ссылки и сноски;
- шрифт, размер, интервал, поля, ширина, тема, ориентация, оформление книги;
- скорочтение 50–1200 WPM, ручной ввод, паузы, навигация по словам/абзацам/главам;
- фиксированная опорная буква, пауза в фоне, управление автоблокировкой;
- отдельные позиции режимов, локальное атомарное хранение, миграция старого прототипа.

Подпись для физического iPhone настраивается в Xcode → Signing & Capabilities.
Флаг `CODE_SIGNING_ALLOWED=NO` используется только в проверках компиляции.

## Проверки

```sh
swiftc -module-cache-path .build/ChecksCache Models.swift ZipArchive.swift \
  Tests/ParserChecks.swift -o .build/parser-checks
.build/parser-checks --large
```

В Debug доступны аргументы запуска `--demo --self-test`: изолированная демонстрационная библиотека
и проверки CoreText. Отчёт сохраняется в Documents/layout-checks.json контейнера симулятора.

Результаты и границы проверки: [docs/verification/RESULTS.md](docs/verification/RESULTS.md).
