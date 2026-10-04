import AppKit

/// Regex-based C++ colouring. Re-colours the whole document on every change,
/// which is fine for the file sizes this editor is meant for.
enum CppHighlighter {
    static let extensions: Set<String> = [
        "c", "cc", "cpp", "cxx", "c++", "h", "hh", "hpp", "hxx", "h++", "inl", "ipp", "tpp",
    ]

    static let keywords: Set<String> = [
        "alignas", "alignof", "and", "and_eq", "asm", "bitand", "bitor", "break", "case", "catch",
        "class", "co_await", "co_return", "co_yield", "compl", "concept", "const", "const_cast",
        "consteval", "constexpr", "constinit", "continue", "decltype", "default", "delete", "do",
        "dynamic_cast", "else", "enum", "explicit", "export", "extern", "false", "final", "for",
        "friend", "goto", "if", "import", "inline", "module", "mutable", "namespace", "new",
        "noexcept", "not", "not_eq", "nullptr", "operator", "or", "or_eq", "override", "private",
        "protected", "public", "register", "reinterpret_cast", "requires", "return", "sizeof",
        "static", "static_assert", "static_cast", "struct", "switch", "template", "this",
        "thread_local", "throw", "true", "try", "typedef", "typeid", "typename", "union", "using",
        "virtual", "volatile", "while", "xor", "xor_eq",
    ]

    static let types: Set<String> = [
        "auto", "bool", "char", "char8_t", "char16_t", "char32_t", "double", "float", "int",
        "long", "short", "signed", "unsigned", "void", "wchar_t", "size_t", "ptrdiff_t",
        "nullptr_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
        "uint64_t", "intptr_t", "uintptr_t", "std", "string", "string_view", "vector", "array",
        "map", "set", "unordered_map", "unordered_set", "pair", "tuple", "optional", "variant",
        "unique_ptr", "shared_ptr", "weak_ptr", "function",
    ]

    // One alternation, so whichever token starts first wins: a "//" inside a
    // string stays a string, a quote inside a comment stays a comment.
    private static let regex = try! NSRegularExpression(
        pattern: [
            #"(?<comment>//[^\n]*|/\*.*?(?:\*/|\z))"#,
            #"(?<string>R"(?<delim>[^()\\\s]{0,16})\(.*?(?:\)\k<delim>"|\z)"#
                + #"|"(?:\\.|[^"\\\n])*"?|'(?:\\.|[^'\\\n])*'?)"#,
            #"(?<preproc>^[ \t]*#[ \t]*(?:include[ \t]*<[^>\n]*>|\w+))"#,
            #"(?<number>\b\d[\w'.]*)"#,
            #"(?<word>\b[A-Za-z_]\w*\b)"#,
        ].joined(separator: "|"),
        options: [.dotMatchesLineSeparators, .anchorsMatchLines])

    static func highlight(_ storage: NSTextStorage, enabled: Bool) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
        guard enabled else { return }

        let text = storage.string as NSString
        regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match else { return }
            let color: NSColor?
            if match.range(withName: "comment").location != NSNotFound {
                color = .systemGreen
            } else if match.range(withName: "string").location != NSNotFound {
                color = .systemRed
            } else if match.range(withName: "preproc").location != NSNotFound {
                color = .systemOrange
            } else if match.range(withName: "number").location != NSNotFound {
                color = .systemPurple
            } else {
                let word = text.substring(with: match.range)
                color = keywords.contains(word) ? .systemPink : types.contains(word) ? .systemTeal : nil
            }
            if let color {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }
}
