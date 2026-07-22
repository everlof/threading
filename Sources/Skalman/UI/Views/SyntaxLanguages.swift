import Foundation

/// The languages the diff highlighter knows, and how a file is matched to one.
///
/// A table rather than a plugin surface: what a coloured diff needs is the shape of a
/// comment, a string and a keyword, and every language here shares one of three lexical
/// families. An extension not listed renders plain, which is honest — a wrong guess colours
/// half a line and reads as a bug in the diff.
enum SyntaxLanguages {

    // MARK: - Families

    /// C-descended: `//` and `/* */`, double-quoted strings, capitalized names read as types.
    private static func curly(
        keywords: String,
        types: String,
        strings: [Character] = ["\"", "'"],
        sigils: Set<Character> = [],
        capitalizedIsType: Bool = true
    ) -> SyntaxLanguage {
        SyntaxLanguage(
            lineComments: ["//"],
            blockComment: (open: "/*", close: "*/"),
            stringDelimiters: strings,
            escapesWithBackslash: true,
            keywords: Set(keywords.split(separator: " ").map(String.init)),
            types: Set(types.split(separator: " ").map(String.init)),
            capitalizedIsType: capitalizedIsType,
            sigils: sigils
        )
    }

    /// `#`-commented scripting languages, which have no block comment worth the ambiguity.
    private static func hashScript(
        keywords: String,
        types: String = "",
        strings: [Character] = ["\"", "'"],
        capitalizedIsType: Bool = false
    ) -> SyntaxLanguage {
        SyntaxLanguage(
            lineComments: ["#"],
            blockComment: nil,
            stringDelimiters: strings,
            escapesWithBackslash: true,
            keywords: Set(keywords.split(separator: " ").map(String.init)),
            types: Set(types.split(separator: " ").map(String.init)),
            capitalizedIsType: capitalizedIsType,
            sigils: []
        )
    }

    // MARK: - Languages

    static let swift = curly(
        keywords: """
        associatedtype async await break case catch class continue default defer deinit do else \
        enum extension fallthrough false fileprivate final for func guard if import in indirect \
        infix init inout internal is lazy let mutating nil none open operator override postfix \
        precedencegroup prefix private protocol public repeat required rethrows return self Self \
        static struct subscript super switch throw throws true try typealias unowned var weak \
        where while some any nonisolated actor consuming borrowing
        """,
        types: "Int Double Float Bool String Character Data Date URL Array Dictionary Set Optional Void Never",
        sigils: ["@", "#"]
    )

    static let cFamily = curly(
        keywords: """
        auto break case char const continue default do double else enum extern float for goto if \
        inline int long register restrict return short signed sizeof static struct switch typedef \
        union unsigned void volatile while bool true false NULL nullptr namespace template class \
        public private protected virtual override new delete this using constexpr noexcept
        """,
        types: "size_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t",
        sigils: ["#", "@"]
    )

    static let javascript = curly(
        keywords: """
        async await break case catch class const continue debugger default delete do else export \
        extends false finally for from function get if implements import in instanceof interface \
        let new null of return set static super switch this throw true try typeof undefined var \
        void while with yield as type declare namespace readonly keyof satisfies enum abstract \
        public private protected
        """,
        types: "string number boolean object symbol bigint any unknown never Promise Array Record",
        strings: ["\"", "'", "`"],
        sigils: ["@"]
    )

    static let java = curly(
        keywords: """
        abstract assert boolean break byte case catch char class const continue default do double \
        else enum extends final finally float for goto if implements import instanceof int \
        interface long native new package private protected public return short static strictfp \
        super switch synchronized this throw throws transient try void volatile while true false \
        null var record sealed permits yield
        """,
        types: "String Integer Boolean Double Float Long List Map Set",
        sigils: ["@"]
    )

    static let kotlin = curly(
        keywords: """
        as break by class companion const constructor continue crossinline data delegate do else \
        enum external false final finally for fun get if import in infix init inline interface \
        internal is lateinit noinline null object open operator out override package private \
        protected public reified return sealed set super suspend tailrec this throw true try \
        typealias val var vararg when where while
        """,
        types: "Int Long Double Float Boolean String Unit Any List Map Set Array Nothing",
        sigils: ["@"]
    )

    static let go = curly(
        keywords: """
        break case chan const continue default defer else fallthrough for func go goto if import \
        interface map package range return select struct switch type var nil true false make new \
        len cap append copy delete panic recover
        """,
        types: "string int int8 int16 int32 int64 uint uint8 uint32 uint64 byte rune float32 float64 bool error any",
        strings: ["\"", "`", "'"]
    )

    static let rust = curly(
        keywords: """
        as async await break const continue crate dyn else enum extern false fn for if impl in \
        let loop match mod move mut pub ref return self Self static struct super trait true type \
        unsafe use where while box macro_rules
        """,
        types: "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box",
        sigils: ["#"]
    )

    static let python = hashScript(
        keywords: """
        and as assert async await break class continue def del elif else except finally for from \
        global if import in is lambda None nonlocal not or pass raise return True False try while \
        with yield match case self
        """,
        types: "int float str bool bytes list dict set tuple object Exception None",
        capitalizedIsType: true
    )

    static let ruby = hashScript(
        keywords: """
        alias and begin break case class def defined do else elsif end ensure false for if in \
        module next nil not or redo rescue retry return self super then true undef unless until \
        when while yield require require_relative attr_accessor attr_reader attr_writer
        """,
        capitalizedIsType: true
    )

    static let shell = hashScript(
        keywords: """
        if then else elif fi case esac for while until do done in function return local export \
        readonly declare unset shift source alias eval exec exit set trap echo cd
        """,
        strings: ["\"", "'"]
    )

    static let yaml = hashScript(keywords: "true false null yes no on off")

    static let toml = hashScript(keywords: "true false")

    /// JSON has no keywords beyond its three literals, and its `"` runs are as often keys as
    /// values — colouring both as strings is what a JSON viewer does anyway.
    static let json = SyntaxLanguage(
        lineComments: [],
        blockComment: nil,
        stringDelimiters: ["\""],
        escapesWithBackslash: true,
        keywords: ["true", "false", "null"],
        types: [],
        capitalizedIsType: false,
        sigils: []
    )

    static let sql = SyntaxLanguage(
        lineComments: ["--"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: ["'", "\""],
        escapesWithBackslash: false,
        keywords: Set("""
        select from where insert into values update set delete create table drop alter add index \
        primary key foreign references join left right inner outer on group by order having limit \
        offset union all distinct as and or not null is in exists between like case when then else \
        end begin commit rollback transaction default constraint unique check cascade
        """.split(separator: " ").map(String.init)),
        types: ["int", "integer", "text", "varchar", "boolean", "date", "timestamp", "real", "blob"],
        capitalizedIsType: false,
        sigils: []
    )

    static let css = SyntaxLanguage(
        lineComments: ["//"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: ["\"", "'"],
        escapesWithBackslash: true,
        keywords: Set("""
        import media supports keyframes from to important inherit initial unset none auto flex \
        grid block inline absolute relative fixed sticky hidden visible
        """.split(separator: " ").map(String.init)),
        types: [],
        capitalizedIsType: false,
        sigils: ["@"]
    )

    // MARK: - Lookup

    static let byExtension: [String: SyntaxLanguage] = [
        "swift": swift,
        "c": cFamily, "h": cFamily, "cc": cFamily, "cpp": cFamily, "cxx": cFamily,
        "hpp": cFamily, "hh": cFamily, "m": cFamily, "mm": cFamily, "cs": cFamily,
        "js": javascript, "jsx": javascript, "mjs": javascript, "cjs": javascript,
        "ts": javascript, "tsx": javascript,
        "java": java,
        "kt": kotlin, "kts": kotlin,
        "go": go,
        "rs": rust,
        "py": python, "pyi": python,
        "rb": ruby, "gemspec": ruby, "rake": ruby,
        "sh": shell, "bash": shell, "zsh": shell, "fish": shell,
        "json": json,
        "yml": yaml, "yaml": yaml,
        "toml": toml,
        "sql": sql,
        "css": css, "scss": css, "less": css
    ]

    /// Files whose name carries the language, where an extension would not.
    static let byFilename: [String: SyntaxLanguage] = [
        "makefile": shell,
        "dockerfile": shell,
        "rakefile": ruby,
        "gemfile": ruby,
        "podfile": ruby,
        "package.json": json,
        ".zshrc": shell,
        ".bashrc": shell,
        ".bash_profile": shell,
        ".gitignore": hashScript(keywords: "")
    ]
}
