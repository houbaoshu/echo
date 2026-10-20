import AppKit

// Presentation only: keep the original text, font, selection and read-only behavior.
enum PreviewSyntaxHighlighter {
    enum Language: CaseIterable {
        case swift, rust, javascript, typescript, python, c, cpp, java, go
        case json, yaml, toml, shell, ruby, html, css, sql

        var keywords: String {
            switch self {
            case .swift: return "actor as associatedtype async await break case catch class continue default defer deinit do else enum extension false fileprivate for func guard if import in init inout internal is let nil nonisolated open private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while"
            case .rust: return "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"
            case .javascript, .typescript: return "abstract as async await boolean break case catch class const constructor continue debugger declare default delete do else enum export extends false finally for from function get if implements import in instanceof interface keyof let namespace never new null number of private protected public readonly return set static string super switch symbol this throw true try type typeof undefined unknown var void while yield"
            case .python: return "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield"
            case .c, .cpp: return "alignas auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern false float for friend if inline int long namespace new nullptr operator private protected public register return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while"
            case .java: return "abstract assert boolean break byte case catch char class continue default do double else enum extends false final finally float for if implements import instanceof int interface long native new null package private protected public record return short static super switch synchronized this throw throws true try var void volatile while"
            case .go: return "break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var"
            case .json: return "true false null"
            case .yaml: return "true false null yes no on off"
            case .toml: return "true false inf nan"
            case .shell: return "if then else elif fi case esac for do done in while until function select time export local readonly return"
            case .ruby: return "alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield"
            case .html: return ""
            case .css: return "important inherit initial unset auto none"
            case .sql: return "select from where insert into values update set delete create alter drop table index join inner left right outer on as and or not null true false group by order having limit offset union all distinct case when then else end exists primary key references default"
            }
        }
    }

    static func language(for path: String) -> Language? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "rs": return .rust
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyw": return .python
        case "c", "h": return .c
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm": return .cpp
        case "java": return .java
        case "go": return .go
        case "json", "jsonc": return .json
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "sh", "bash", "zsh": return .shell
        case "rb": return .ruby
        case "html", "htm", "xml", "svg": return .html
        case "css", "scss": return .css
        case "sql": return .sql
        default: return nil
        }
    }

    private struct Grammar {
        let expression: NSRegularExpression
        let colors: [NSColor]
    }

    private static let grammars: [Language: Grammar] = Dictionary(uniqueKeysWithValues: Language.allCases.map { language in
        var rules: [(String, NSColor)] = []
        switch language {
        case .python, .yaml, .toml, .shell, .ruby:
            rules.append((#"#[^\r\n]*"#, .secondaryLabelColor))
        case .html:
            rules.append((#"<!--[\s\S]*?(?:-->|\z)"#, .secondaryLabelColor))
        case .sql:
            rules.append((#"--[^\r\n]*|/\*[\s\S]*?(?:\*/|\z)"#, .secondaryLabelColor))
        case .css:
            rules.append((#"/\*[\s\S]*?(?:\*/|\z)"#, .secondaryLabelColor))
        default:
            rules.append((#"//[^\r\n]*|/\*[\s\S]*?(?:\*/|\z)"#, .secondaryLabelColor))
        }
        if [.python, .swift, .toml].contains(language) {
            rules.append((#"\"\"\"[\s\S]*?(?:\"\"\"|\z)|'''[\s\S]*?(?:'''|\z)"#, .systemRed))
        }
        if [.javascript, .typescript, .go, .shell].contains(language) {
            rules.append((#"`(?:\\[\s\S]|[^`\\])*(?:`|\z)"#, .systemRed))
        }
        rules.append((#"\"(?:\\[\s\S]|[^\"\\\r\n])*(?:\"|$)|'(?:\\[\s\S]|[^'\\\r\n])*(?:'|$)"#, .systemRed))
        if language == .html {
            rules.append((#"</?[A-Za-z][\w:.-]*|/?>"#, .systemPurple))
        }
        if !language.keywords.isEmpty {
            let words = language.keywords.split(separator: " ").joined(separator: "|")
            rules.append(("\\b(?:\(words))\\b", .systemPurple))
        }
        rules.append((#"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9]+)?)\b"#, .systemBlue))
        // One scan keeps keywords and comment markers inside strings from being recolored.
        let pattern = rules.map { "(\($0.0))" }.joined(separator: "|")
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if language == .sql { options.insert(.caseInsensitive) }
        return (language, Grammar(expression: try! NSRegularExpression(pattern: pattern, options: options), colors: rules.map(\.1)))
    })

    static func apply(to storage: NSTextStorage, language: Language?) {
        let range = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        guard let language, let grammar = grammars[language] else { return }
        grammar.expression.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match, let rule = grammar.colors.indices.first(where: {
                match.range(at: $0 + 1).location != NSNotFound
            }) else { return }
            storage.addAttribute(.foregroundColor, value: grammar.colors[rule], range: match.range)
        }
    }
}
