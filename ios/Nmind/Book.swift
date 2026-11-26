import Foundation

/// One paragraph of a book as stored. `sec` names a chapter or section that starts here.
struct BookPara: Codable {
    var t: String
    var sec: String?
}

/// A book as kept on the phone: the built-in one, or one loaded from Files.
struct StoredBook: Codable {
    var id: String
    var title: String
    var credit: String
    var source: String
    var paras: [BookPara]
}

/// A book ready for the feed: its words, the pieces the voice reads one at a time, and its chapters.
final class Book {
    struct Chunk { let text: String; let first: Int; let count: Int }
    struct Section { let title: String; let range: Range<Int> }

    let id: String
    let title: String
    let credit: String
    let source: String
    let words: [String]
    let chunks: [Chunk]
    let sections: [Section]
    /// the chapter closest to the book's average chapter length, for the one-chapter option
    let chapter: Section?

    init(_ s: StoredBook) {
        id = s.id; title = s.title; credit = s.credit; source = s.source
        var w: [String] = [], c: [Chunk] = [], starts: [(String, Int)] = []
        var buf: [String] = [], first = 0, len = 0
        func flush() {
            if !buf.isEmpty { c.append(Chunk(text: buf.joined(separator: " "), first: first, count: buf.count)) }
            buf = []; len = 0
        }
        for p in s.paras {
            let pw = p.t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !pw.isEmpty else { continue }
            if let title = p.sec {
                // a chapter always starts a new piece, so a chapter can be read on its own
                flush()
                // a heading followed straight away by another (a title, then a run-in opening) is one chapter
                if let last = starts.last, w.count - last.1 < 30 {} else { starts.append((title, w.count)) }
            }
            for word in pw {
                if buf.isEmpty { first = w.count }
                buf.append(word); w.append(word); len += word.count + 1
                // a piece is a paragraph or a few sentences, so speech is made a little ahead of playback
                if (len > 280 && Book.endsSentence(word)) || len > 900 { flush() }
            }
            if len > 280 { flush() }
        }
        flush()
        words = w
        chunks = c
        sections = starts.enumerated().map { i, s in
            Section(title: s.0, range: s.1..<(i + 1 < starts.count ? starts[i + 1].1 : w.count))
        }
        let real = sections.filter { $0.range.count >= 300 }
        if real.count >= 2 {
            let mean = Double(real.reduce(0) { $0 + $1.range.count }) / Double(real.count)
            chapter = real.min { abs(Double($0.range.count) - mean) < abs(Double($1.range.count) - mean) }
        } else if w.count >= 900, !c.isEmpty {
            // no chapters marked: a passage of about 1,500 words from a third of the way in
            let k = c.firstIndex { $0.first >= w.count / 3 } ?? 0
            let start = c[k].first
            let end = c.first { $0.first >= start + min(1500, w.count / 3) }?.first ?? w.count
            chapter = Section(title: "A passage", range: start..<end)
        } else {
            chapter = nil
        }
    }

    static func endsSentence(_ w: String) -> Bool {
        guard let l = w.last else { return false }
        if ".!?".contains(l) { return true }
        if "\"\u{201D}')\u{2019}".contains(l), w.count > 1 {
            return ".!?".contains(w[w.index(before: w.index(before: w.endIndex))])
        }
        return false
    }

    /// The built-in book, As a Man Thinketh, with its chapter headings.
    static var builtIn: StoredBook {
        let paras = BookText.body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { p -> BookPara in
                let pw = p.split(whereSeparator: { $0.isWhitespace })
                let heading = pw.count <= 9 && p.hasSuffix(".") && pw.allSatisfy { $0.first?.isUppercase ?? false }
                return BookPara(t: p, sec: heading ? String(p.dropLast()) : nil)
            }
        return StoredBook(id: BookShelf.builtInID, title: BookText.title,
                          credit: "\(BookText.author), 1903. Public domain.", source: "Built in", paras: paras)
    }
}

/// The books loaded onto this phone. They are kept in the app's own storage, left out of iCloud
/// backups, and never uploaded anywhere.
enum BookShelf {
    static let builtInID = "builtin.thinketh"

    struct Entry: Codable, Identifiable {
        var id: String
        var title: String
        var credit: String
        var source: String
        var words: Int
    }

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var d = base.appendingPathComponent("Books", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var v = URLResourceValues(); v.isExcludedFromBackup = true
            try? d.setResourceValues(v)
        }
        return d
    }
    private static var indexURL: URL { dir.appendingPathComponent("index.json") }

    static func list() -> [Entry] {
        guard let d = try? Data(contentsOf: indexURL),
              let e = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return e
    }

    static func save(_ b: StoredBook) throws {
        let data = try JSONEncoder().encode(b)
        var url = dir.appendingPathComponent("\(b.id).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? url.setResourceValues(v)
        var all = list().filter { $0.id != b.id }
        let words = b.paras.reduce(0) { $0 + $1.t.split(whereSeparator: { $0.isWhitespace }).count }
        all.append(Entry(id: b.id, title: b.title, credit: b.credit, source: b.source, words: words))
        try JSONEncoder().encode(all).write(to: indexURL, options: .atomic)
    }

    static func load(_ id: String) -> StoredBook? {
        if id == builtInID { return Book.builtIn }
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")) else { return nil }
        return try? JSONDecoder().decode(StoredBook.self, from: d)
    }

    static func remove(_ id: String) {
        guard id != builtInID else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        let rest = list().filter { $0.id != id }
        if let d = try? JSONEncoder().encode(rest) { try? d.write(to: indexURL, options: .atomic) }
    }
}
