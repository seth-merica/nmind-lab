import Foundation
import PDFKit
import Compression

/// Why a picked file couldn't become a book.
enum BookLoadError: LocalizedError {
    case drm, unreadable, tooShort, unsupported

    var errorDescription: String? {
        switch self {
        case .drm: return "That book is copy-protected, so it can't be read here. Kindle and Apple Books purchases are locked this way. Try a DRM-free EPUB or PDF."
        case .unreadable: return "That file couldn't be read. Try a DRM-free EPUB, PDF or plain text file."
        case .tooShort: return "That file has too little text to feed (under 300 words). A scanned PDF has no text layer, so it reads as empty."
        case .unsupported: return "Only EPUB, PDF and plain text files can be loaded."
        }
    }
}

/// Turns a DRM-free EPUB, PDF or plain text file into a stored book, on the phone, with nothing sent anywhere.
enum BookLoader {
    static func load(_ url: URL) throws -> StoredBook {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        var title = name, author: String?
        var paras: [BookPara]
        switch ext {
        case "epub":
            let r = try EPUB.read(url)
            paras = r.paras
            if let t = r.title, !t.isEmpty { title = t }
            author = r.author
        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw BookLoadError.unreadable }
            if doc.isLocked && !doc.unlock(withPassword: "") { throw BookLoadError.drm }
            if doc.isEncrypted && doc.isLocked { throw BookLoadError.drm }
            paras = PDFText.paras(doc)
            let attrs = doc.documentAttributes ?? [:]
            if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String, t.trimmingCharacters(in: .whitespaces).count > 2 { title = t }
            if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String, !a.trimmingCharacters(in: .whitespaces).isEmpty { author = a }
        case "txt", "text", "md", "":
            guard let d = try? Data(contentsOf: url) else { throw BookLoadError.unreadable }
            guard let s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) else { throw BookLoadError.unreadable }
            paras = PlainText.paras(s)
        default:
            throw BookLoadError.unsupported
        }
        paras = paras.map { BookPara(t: Prose.squash($0.t), sec: $0.sec.map(Prose.squash)) }.filter { !$0.t.isEmpty }
        let words = paras.reduce(0) { $0 + $1.t.split(whereSeparator: { $0.isWhitespace }).count }
        guard words >= 300 else { throw BookLoadError.tooShort }
        return StoredBook(id: UUID().uuidString, title: Prose.squash(title),
                          credit: author.map { Prose.squash($0) } ?? "Loaded from your files",
                          source: ext.uppercased().isEmpty ? "TXT" : ext.uppercased(), paras: paras)
    }
}

// MARK: shared text helpers

private enum Prose {
    static func squash(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00AD}", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static let romans: Set<String> = ["I","II","III","IV","V","VI","VII","VIII","IX","X","XI","XII","XIII","XIV","XV",
                                      "XVI","XVII","XVIII","XIX","XX","XXI","XXII","XXIII","XXIV","XXV"]

    /// A short line that names a chapter: "Chapter 3", "PART TWO", "IV", or a short line in capitals.
    static func heading(_ line: String) -> Bool {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, l.count <= 70 else { return false }
        let w = l.split(separator: " ")
        guard w.count <= 10 else { return false }
        let lower = l.lowercased()
        if lower.hasPrefix("chapter ") || lower.hasPrefix("part ") || lower.hasPrefix("book ") { return true }
        if romans.contains(l.trimmingCharacters(in: CharacterSet(charactersIn: "."))) { return true }
        let letters = l.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 3 else { return false }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        if Double(upper) / Double(letters.count) > 0.9, !l.hasSuffix(",") { return true }
        return false
    }
}

// MARK: plain text

private enum PlainText {
    static func paras(_ s: String) -> [BookPara] {
        let text = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        let blank = lines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        // blank lines between paragraphs, or one paragraph per line when blank lines are rare
        let blocks: [String]
        if blank * 8 >= lines.count {
            blocks = text.components(separatedBy: "\n\n")
        } else {
            blocks = lines
        }
        return blocks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { b in
            let one = b.replacingOccurrences(of: "\n", with: " ")
            return Prose.heading(one) && !b.contains("\n") ? BookPara(t: one, sec: one) : BookPara(t: one, sec: nil)
        }
    }
}

// MARK: PDF

private enum PDFText {
    static func paras(_ doc: PDFDocument) -> [BookPara] {
        var pages: [[String]] = []
        for i in 0..<doc.pageCount {
            let s = doc.page(at: i)?.string ?? ""
            let lines = s.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            pages.append(lines)
        }
        // running headers and footers: short lines (digits ignored) that repeat on a fifth of the pages or more
        var seen: [String: Int] = [:]
        func key(_ l: String) -> String { l.filter { !$0.isNumber }.trimmingCharacters(in: .whitespaces).lowercased() }
        for p in pages {
            let edge = Array(p.filter { !$0.isEmpty }.prefix(2)) + Array(p.filter { !$0.isEmpty }.suffix(2))
            for l in Set(edge.map(key)) where !l.isEmpty && l.count < 80 { seen[l, default: 0] += 1 }
        }
        let limit = max(3, pages.count / 5)
        let running = Set(seen.filter { $0.value >= limit }.keys)

        var out: [BookPara] = []
        var cur = ""
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(BookPara(t: t, sec: nil)) }
            cur = ""
        }
        func add(_ l: String) {
            if cur.isEmpty { cur = l; return }
            if cur.hasSuffix("-"), let f = l.first, f.isLowercase {
                cur.removeLast(); cur += l           // a word broken across lines
            } else {
                cur += " " + l
            }
        }
        for p in pages {
            var lines = p
            // page numbers alone on a line
            lines = lines.filter { l in
                let t = l.trimmingCharacters(in: CharacterSet(charactersIn: " -–—."))
                if t.isEmpty { return true }
                if t.allSatisfy({ $0.isNumber }) { return false }
                if Prose.romans.contains(t.uppercased()) && t.count <= 4 && t == t.lowercased() { return false }
                return !(running.contains(key(l)) && l.count < 80)
            }
            for l in lines {
                if l.isEmpty { flush(); continue }
                if Prose.heading(l) && l.count < 60 {
                    flush()
                    out.append(BookPara(t: l, sec: l))
                    continue
                }
                add(l)
                // a line well short of the page width that ends a sentence usually ends a paragraph
                if l.count < 45, Book.endsSentence(l.split(separator: " ").last.map(String.init) ?? "") { flush() }
            }
        }
        flush()
        // run-in openings in capitals ("WHEN I WAS a boy...") start a section when nothing else marks one
        if !out.contains(where: { $0.sec != nil }) {
            out = out.map { p in
                let w = p.t.split(separator: " ").prefix(4).map(String.init)
                let caps = w.prefix { $0.count > 1 && $0 == $0.uppercased() && $0.contains(where: { $0.isLetter }) }
                if caps.count >= 2, p.t.split(separator: " ").count > 40 {
                    return BookPara(t: p.t, sec: caps.joined(separator: " ").capitalized)
                }
                return p
            }
        }
        // merge headings that are really one line split in two
        var merged: [BookPara] = []
        for p in out {
            if let s = p.sec, p.t == s, let last = merged.last, let ls = last.sec, last.t == ls, ls.count + s.count < 70 {
                merged[merged.count - 1] = BookPara(t: ls + " " + s, sec: ls + " " + s)
            } else {
                merged.append(p)
            }
        }
        return merged
    }
}

// MARK: EPUB

private enum EPUB {
    struct Result { let title: String?; let author: String?; let paras: [BookPara] }

    static func read(_ url: URL) throws -> Result {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw BookLoadError.unreadable }
        let zip = try Zip(data)
        if zip.has("META-INF/rights.xml") { throw BookLoadError.drm }
        if let enc = zip.text("META-INF/encryption.xml") {
            // fonts may be obfuscated in a free book; anything else encrypted means DRM
            let uris = matches(enc, #"URI\s*=\s*"([^"]+)""#)
            if uris.contains(where: { u in !["ttf", "otf", "woff", "woff2"].contains((u as NSString).pathExtension.lowercased()) }) {
                throw BookLoadError.drm
            }
        }
        guard let container = zip.text("META-INF/container.xml"),
              let opfPath = matches(container, #"full-path\s*=\s*"([^"]+)""#).first,
              let opf = zip.text(opfPath) else { throw BookLoadError.unreadable }
        let base = (opfPath as NSString).deletingLastPathComponent

        let title = matches(opf, #"<dc:title[^>]*>([\s\S]*?)</dc:title>"#).first.map(decode)
        let author = matches(opf, #"<dc:creator[^>]*>([\s\S]*?)</dc:creator>"#).first.map(decode)

        // manifest id → (href, properties)
        var manifest: [String: (String, String)] = [:]
        for item in matches(opf, #"(<item\b[^>]*>)"#) {
            guard let id = attr(item, "id"), let href = attr(item, "href") else { continue }
            manifest[id] = (href, attr(item, "properties") ?? "")
        }
        var paras: [BookPara] = []
        var part = 0
        for ref in matches(opf, #"(<itemref\b[^>]*>)"#) {
            guard let idref = attr(ref, "idref"), let entry = manifest[idref] else { continue }
            let (href, props) = entry
            if attr(ref, "linear") == "no" || props.contains("nav") { continue }
            let path = base.isEmpty ? href : base + "/" + href
            let clean = (path.removingPercentEncoding ?? path)
            guard let html = zip.text(normalize(clean)) else { continue }
            var doc = xhtmlParas(html)
            let words = doc.reduce(0) { $0 + $1.t.split(separator: " ").count }
            guard words > 0 else { continue }
            part += 1
            if !doc.contains(where: { $0.sec != nil }), words >= 300 {
                doc[0] = BookPara(t: doc[0].t, sec: "Part \(part)")
            }
            paras += doc
        }
        return Result(title: title, author: author, paras: paras)
    }

    private static func normalize(_ p: String) -> String {
        var out: [String] = []
        for c in p.split(separator: "/") {
            if c == ".." { if !out.isEmpty { out.removeLast() } } else if c != "." { out.append(String(c)) }
        }
        return out.joined(separator: "/")
    }

    /// Paragraphs from one XHTML file, with h1 to h3 as chapter headings.
    static func xhtmlParas(_ html: String) -> [BookPara] {
        var s = html
        if let r = s.range(of: "<body", options: .caseInsensitive) { s = String(s[r.lowerBound...]) }
        for tag in ["script", "style", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // mark headings, then break on block ends
        s = s.replacingOccurrences(of: "<h[1-3]\\b[^>]*>", with: "\u{1}", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</h[1-3]\\s*>", with: "\u{2}\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|li|blockquote|h[4-6]|tr|section)\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        var out: [BookPara] = []
        for raw in s.components(separatedBy: "\n") {
            var line = raw
            var isHead = false
            if line.contains("\u{1}") {
                isHead = true
                line = line.replacingOccurrences(of: "\u{1}", with: " ").replacingOccurrences(of: "\u{2}", with: " ")
            }
            let t = Prose.squash(decode(line))
            guard !t.isEmpty else { continue }
            if isHead && t.count <= 120 {
                out.append(BookPara(t: t, sec: t))
            } else {
                out.append(BookPara(t: t, sec: nil))
            }
        }
        return out
    }

    // MARK: small XML helpers

    static func matches(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    static func attr(_ tag: String, _ name: String) -> String? {
        matches(tag, "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']").first
    }

    static func decode(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
                     "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}", "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}",
                     "&mdash;": ", ", "&ndash;": "-", "&hellip;": "...", "&shy;": ""]
        for (k, v) in named { r = r.replacingOccurrences(of: k, with: v) }
        // numeric references
        guard r.contains("&#") else { return r }
        let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = r as NSString
        var out = "", last = 0
        for m in re?.matches(in: r, range: NSRange(location: 0, length: ns.length)) ?? [] {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let v = UInt32(num, radix: hex ? 16 : 10), let u = Unicode.Scalar(v) {
                out += (v == 0x2014) ? ", " : String(Character(u))
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

/// Just enough of a zip reader for an EPUB: the central directory, stored and deflated entries.
private struct Zip {
    struct Entry { let method: Int; let csize: Int; let usize: Int; let offset: Int }
    let data: Data
    var entries: [String: Entry] = [:]

    init(_ data: Data) throws {
        self.data = data
        let n = data.count
        guard n > 22 else { throw BookLoadError.unreadable }
        // end of central directory record, searched from the end
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65_536)
        while i >= stop {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw BookLoadError.unreadable }
        let count = u16(eocd + 10)
        var p = u32i(eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x02014b50 else { throw BookLoadError.unreadable }
            let flags = u16(p + 8)
            let method = u16(p + 10)
            let csize = u32i(p + 20), usize = u32i(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32i(p + 42)
            guard p + 46 + nameLen <= n else { throw BookLoadError.unreadable }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            if flags & 1 == 1, !name.hasPrefix("META-INF") { throw BookLoadError.drm }   // zip-encrypted
            entries[name] = Entry(method: method, csize: csize, usize: usize, offset: local)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    private func byte(_ i: Int) -> UInt32 { UInt32(data[data.startIndex + i]) }
    private func u16(_ i: Int) -> Int { Int(byte(i) | byte(i + 1) << 8) }
    private func u32(_ i: Int) -> UInt32 { byte(i) | byte(i + 1) << 8 | byte(i + 2) << 16 | byte(i + 3) << 24 }
    private func u32i(_ i: Int) -> Int { Int(u32(i)) }

    func has(_ name: String) -> Bool { entries[name] != nil }

    func bytes(_ name: String) -> Data? {
        guard let e = entries[name] ?? entries.first(where: { $0.key.lowercased() == name.lowercased() })?.value else { return nil }
        let n = data.count
        guard e.offset + 30 <= n, u32(e.offset) == 0x04034b50 else { return nil }
        let start = e.offset + 30 + u16(e.offset + 26) + u16(e.offset + 28)
        guard start + e.csize <= n else { return nil }
        let comp = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.csize))
        switch e.method {
        case 0: return comp
        case 8:
            guard e.usize > 0, e.usize < 64_000_000 else { return e.usize == 0 ? Data() : nil }
            var out = Data(count: e.usize)
            let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                comp.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, e.usize, s, e.csize, nil, COMPRESSION_ZLIB)
                }
            }
            return written > 0 ? out.prefix(written) : nil
        default: return nil
        }
    }

    func text(_ name: String) -> String? {
        guard let d = bytes(name) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }
}
