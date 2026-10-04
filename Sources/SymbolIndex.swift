import Foundation

/// The autocomplete index: every identifier of the project, sorted, in a
/// binary layout that is searched in place (the file is memory-mapped, never
/// parsed).
///
/// `.autocmp` layout, all integers little-endian:
///
///     "ACMP" | version: u32 | count: u32
///     count × { offset: u32, length: u32 }   one record per symbol, sorted by name bytes
///     names, UTF-8, back to back             offset is from the start of the file
///
/// Fixed-size records make a prefix lookup a binary search over the records.
struct SymbolIndex {
    static let fileName = ".autocmp"

    /// Language words only: used before any project index exists.
    static let builtin = SymbolIndex(data: build(from: []))

    private static let magic = Array("ACMP".utf8)
    private static let version: UInt32 = 1
    private static let headerSize = 12
    private static let recordSize = 8

    private let data: Data
    private let count: Int

    init?(data: Data) {
        guard data.count >= Self.headerSize, data.prefix(4).elementsEqual(Self.magic) else { return nil }
        let (version, count) = data.withUnsafeBytes {
            (Self.u32($0, 4), Int(Self.u32($0, 8)))
        }
        guard version == Self.version, data.count >= Self.headerSize + count * Self.recordSize else { return nil }
        self.data = data
        self.count = count
    }

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    /// Symbols starting with `prefix` (case-sensitive), in sorted order. The
    /// prefix itself is left out: completing a word to itself is noise.
    func complete(_ prefix: String, limit: Int) -> [String] {
        let key = Array(prefix.utf8)
        guard !key.isEmpty else { return [] }
        return data.withUnsafeBytes { bytes in
            // First symbol that does not sort before the prefix.
            var low = 0
            var high = count
            while low < high {
                let middle = (low + high) / 2
                if Self.name(bytes, middle).lexicographicallyPrecedes(key) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            var result: [String] = []
            while low < count, result.count < limit {
                let name = Self.name(bytes, low)
                guard name.starts(with: key) else { break }
                if name.count > key.count { result.append(String(decoding: name, as: UTF8.self)) }
                low += 1
            }
            return result
        }
    }

    private static func u32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    /// Name bytes of record `index`; empty if a damaged file points outside itself.
    private static func name(_ bytes: UnsafeRawBufferPointer, _ index: Int) -> UnsafeRawBufferPointer {
        let record = headerSize + index * recordSize
        let offset = Int(u32(bytes, record))
        let length = Int(u32(bytes, record + 4))
        guard offset + length <= bytes.count else { return UnsafeRawBufferPointer(rebasing: bytes[0..<0]) }
        return UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + length])
    }

    // MARK: - Building

    // Comments and literals are matched only to be skipped, so that words
    // inside them are not indexed.
    private static let scanner = try! NSRegularExpression(
        pattern: #"//[^\n]*|/\*.*?(?:\*/|\z)|"(?:\\.|[^"\\\n])*"?|'(?:\\.|[^'\\\n])*'?"#
            + #"|(?<word>\b[A-Za-z_]\w*)"#,
        options: [.dotMatchesLineSeparators])

    /// Indexes the identifiers of the given sources, plus the C++ keywords
    /// and common types, and returns the contents of an `.autocmp` file.
    static func build(from sources: [String]) -> Data {
        var names = CppHighlighter.keywords.union(CppHighlighter.types)
        for source in sources {
            let text = source as NSString
            scanner.enumerateMatches(in: source, range: NSRange(location: 0, length: text.length)) { match, _, _ in
                // Shorter words are quicker to type than to pick from a list.
                guard let range = match?.range(withName: "word"), range.location != NSNotFound, range.length >= 3
                else { return }
                names.insert(text.substring(with: range))
            }
        }
        let sorted = names.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }

        var data = Data(magic)
        func append(_ value: Int) {
            withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) }
        }
        append(Int(version))
        append(sorted.count)
        var offset = headerSize + sorted.count * recordSize
        for name in sorted {
            append(offset)
            append(name.count)
            offset += name.count
        }
        for name in sorted { data.append(contentsOf: name) }
        return data
    }
}

// Keeping the index of the open project (or lone file) on disk and in memory.
extension EditorModel {
    /// The index sits in the project folder, or beside a file opened on its own.
    private var indexURL: URL? {
        (folderURL ?? fileURL?.deletingLastPathComponent())?.appendingPathComponent(SymbolIndex.fileName)
    }

    /// Uses the index saved by an earlier session right away, then refreshes it.
    func loadIndex() {
        symbols = indexURL.flatMap(SymbolIndex.init(contentsOf:))
        reindex()
    }

    /// Rebuilds `.autocmp` from the sources on disk, off the main thread.
    func reindex() {
        guard let indexURL else { return }
        let files: [URL]
        if let folderURL {
            files = indexedFiles(in: folderURL)
        } else if let fileURL, isCpp {
            files = [fileURL]
        } else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let data = SymbolIndex.build(from: files.compactMap { try? String(contentsOf: $0, encoding: .utf8) })
            try? data.write(to: indexURL, options: .atomic)
            DispatchQueue.main.async {
                // The project may have changed while indexing.
                if self.indexURL == indexURL { self.symbols = SymbolIndex(data: data) }
            }
        }
    }

    func completions(for prefix: String) -> [String] {
        (symbols ?? SymbolIndex.builtin)?.complete(prefix, limit: 40) ?? []
    }

    /// C and C++ sources and headers of the project, skipping build output.
    private func indexedFiles(in folder: URL) -> [URL] {
        let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var result: [URL] = []
        while let url = walker?.nextObject() as? URL {
            if url.hasDirectoryPath {
                let dir = url.lastPathComponent
                if dir == "build" || dir.hasPrefix("cmake-build") { walker?.skipDescendants() }
            } else if CppHighlighter.extensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }
}
