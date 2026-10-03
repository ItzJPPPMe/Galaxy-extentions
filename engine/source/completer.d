import std.algorithm : any, canFind, sort;
import std.ascii : isAlphaNum, isDigit, isUpper;
import std.string : endsWith, indexOf, lastIndexOf, splitLines, startsWith, strip, stripRight, toLower;

enum ProtocolVersion = "1.0.0";

private immutable string[] declarationPrefixes = [
    "class ", "def ", "function ", "fun ", "fn ", "impl ", "interface ",
    "module ", "namespace ", "object ", "package ", "struct ", "trait ", "type ",
    "typedef ", "union ", "enum ", "record ", "component "
];

private immutable string[] importPrefixes = [
    "from ", "import ", "require ", "use ", "using "
];

private immutable string[] scopeKeywords = [
    "class", "interface", "module", "namespace", "package", "struct", "trait", "type", "union"
];

struct CompletionRequest
{
    string filePath;
    string languageId;
    int line;
    int character;
    string prefix;
    string suffix;
    string currentLine;
    string[] previousLines;
    string[] nextLines;
    bool insideComment;
    bool insideString;
}

struct CompletionItem
{
    string label;
    string text;
    string detail;
    string kind;
    string documentation;
    int score;
    bool inline;
}

struct CompletionResponse
{
    string trigger;
    string inlineText;
    bool isIncomplete;
    CompletionItem[] items;
}

struct Snippet
{
    string label;
    string body;
    string detail;
}

struct LanguageProfile
{
    string language;
    string[] keywords;
    string[] functions;
    string[] types;
    string[] modules;
    Snippet[] snippets;
}

struct MemberGroup
{
    string owner;
    string[] names;
}

final class Completer
{
    private LanguageProfile[] profiles;
    private MemberGroup[] members;
    private size_t maxItems;

    this(size_t capacity = 32)
    {
        profiles = buildProfiles();
        members = buildMembers();
        this.maxItems = capacity;
    }

    CompletionResponse complete(CompletionRequest request)
    {
        CompletionResponse response;
        response.trigger = detectTrigger(request);

        CompletionItem[] candidates = gatherCandidates(request);
        candidates = dedupe(candidates);

        CompletionItem[] ranked;
        foreach (item; candidates)
        {
            if (!matchesPrefix(item.label, request.prefix))
                continue;

            CompletionItem scored = item;
            scored.score = scoreItem(item, request) + contextBoost(item, request);
            if (scored.score <= 0)
                continue;

            ranked ~= scored;
        }

        sort!((a, b) => a.score > b.score)(ranked);

        if (ranked.length > maxItems)
        {
            response.items = ranked[0 .. maxItems].dup;
            response.isIncomplete = true;
        }
        else
        {
            response.items = ranked;
        }

        int bestScore = 0;
        foreach (item; response.items)
        {
            if (!item.inline || item.score <= bestScore)
                continue;

            bestScore = item.score;
            response.inlineText = item.text;
        }

        return response;
    }

    private CompletionItem[] gatherCandidates(CompletionRequest request)
    {
        CompletionItem[] items = profileCandidates(request);
        items ~= memberCandidates(request);
        items ~= snippetCandidates(request);
        return items;
    }

    private CompletionItem[] profileCandidates(CompletionRequest request)
    {
        CompletionItem[] items;

        LanguageProfile profile = findProfile(request.languageId);
        if (profile.language.length == 0)
            return items;

        foreach (keyword; profile.keywords)
            items ~= CompletionItem(keyword, keyword, keyword, "keyword", "", 300, false);

        foreach (functionName; profile.functions)
            items ~= CompletionItem(functionName, functionName ~ "()", functionName ~ "()", "function", "", 340, false);

        foreach (typeName; profile.types)
            items ~= CompletionItem(typeName, typeName, typeName, "type", "", 320, false);

        foreach (moduleName; profile.modules)
            items ~= CompletionItem(moduleName, moduleName, "module " ~ moduleName, "module", "", 260, false);

        return items;
    }

    private CompletionItem[] snippetCandidates(CompletionRequest request)
    {
        CompletionItem[] items;

        LanguageProfile profile = findProfile(request.languageId);
        if (profile.language.length == 0)
            return items;

        foreach (snippet; profile.snippets)
        {
            bool inside = request.prefix.length == 0 || snippet.label.toLower.startsWith(request.prefix.toLower);
            items ~= CompletionItem(snippet.label, snippet.body, snippet.detail, "snippet", "", 420, inside);
        }

        return items;
    }

    private CompletionItem[] memberCandidates(CompletionRequest request)
    {
        CompletionItem[] items;

        string head = headOf(request);
        if (head.length == 0)
            return items;

        auto dotIndex = head.lastIndexOf('.');
        if (dotIndex == size_t.max)
            return items;

        string owner = head[dotIndex + 1 .. $];
        if (owner.length == 0 || owner.canFind(' '))
            return items;

        foreach (group; members)
        {
            if (group.owner.toLower != owner.toLower)
                continue;

            foreach (name; group.names)
                items ~= CompletionItem(name, name, group.owner ~ "." ~ name, "member", "", 640, true);
        }

        return items;
    }

    private LanguageProfile findProfile(string languageId)
    {
        LanguageProfile fallback;

        foreach (profile; profiles)
        {
            if (profile.language == languageId)
                return profile;

            if (profile.language == "*" && fallback.language.length == 0)
                fallback = profile;
        }

        return fallback;
    }

    private static CompletionItem[] dedupe(CompletionItem[] items)
    {
        CompletionItem[] result;
        bool[string] seen;

        foreach (item; items)
        {
            if (item.label.length == 0 || item.label in seen)
                continue;

            seen[item.label] = true;
            result ~= item;
        }

        return result;
    }

    private static int scoreItem(CompletionItem item, CompletionRequest request)
    {
        int score = item.score;
        string prefix = request.prefix;
        string lowerLabel = item.label.toLower;
        string lowerPrefix = prefix.toLower;

        if (prefix.length > 0)
        {
            if (lowerLabel == lowerPrefix)
                score += 420;
            else if (lowerLabel.startsWith(lowerPrefix))
                score += 260;
            else if (camelParts(item.label).canFind(lowerPrefix))
                score += 170;
            else if (lowerLabel.indexOf(lowerPrefix) >= 0)
                score += 80;

            score += cast(int)(item.label.startsWith(prefix) ? 40 : 0);

            size_t excess = item.label.length > prefix.length ? item.label.length - prefix.length : 0;
            score -= cast(int)(excess / 4);
        }

        if (request.insideComment)
            score -= 700;
        else if (request.insideString)
            score -= 500;

        if (isAlphaNum(request.currentLine.length > 0 ? request.currentLine[$ - 1] : ' '))
            score += 25;

        return score;
    }

    private static int contextBoost(CompletionItem item, CompletionRequest request)
    {
        int boost = 0;
        string previous = lastMeaningfulLine(request);
        string head = headOf(request);
        string trimmedPrevious = previous.strip;

        if (item.kind == "type" && scopeKeywords.canFind(trimmedPrevious))
            boost += 110;

        if (item.kind == "module" && head.canFind("import"))
            boost += 180;

        if (item.kind == "keyword" && trimmedPrevious.canFind("import"))
            boost -= 60;

        if (item.kind == "function" && request.currentLine.canFind('('))
            boost += 25;

        if (request.languageId == "d" && item.kind == "function")
            boost += 40;

        if (trimmedPrevious.endsWith(";") && item.kind == "keyword")
            boost -= 20;

        if (declarationPrefixes.canFind(trimmedPrevious) && item.kind == "type")
            boost += 90;

        if (importPrefixes.any!(prefix => trimmedPrevious.toLower.startsWith(prefix))())
            boost += 40;

        return boost;
    }

    private static string detectTrigger(CompletionRequest request)
    {
        string head = headOf(request);

        if (request.insideComment)
            return "comment";

        if (request.insideString)
            return "string";

        if (head.endsWith("."))
            return "member";

        if (importPrefixes.any!(prefix => head.toLower.startsWith(prefix))())
            return "import";

        if (declarationPrefixes.any!(prefix => head.toLower.startsWith(prefix))())
            return "declaration";

        if (request.prefix.length > 0)
            return "identifier";

        return "unknown";
    }

    private static bool matchesPrefix(string label, string prefix)
    {
        if (prefix.length == 0)
            return true;

        string lowerLabel = label.toLower;
        string lowerPrefix = prefix.toLower;

        if (lowerLabel.startsWith(lowerPrefix))
            return true;

        foreach (part; camelParts(label))
        {
            if (part.toLower.startsWith(lowerPrefix))
                return true;
        }

        return false;
    }

    private static string[] camelParts(string value)
    {
        string[] parts;
        size_t start = 0;

        foreach (index, character; value)
        {
            if (index > 0 && isUpper(character) && !isUpper(value[index - 1]))
            {
                parts ~= value[start .. index];
                start = index;
            }
        }

        if (start < value.length)
            parts ~= value[start .. $];

        string[] result;
        foreach (part; parts)
        {
            string cleaned = part;
            while (cleaned.length > 0 && (cleaned[0] == '_' || cleaned[0] == ' '))
                cleaned = cleaned[1 .. $];
            while (cleaned.length > 0 && (cleaned[$ - 1] == '_' || cleaned[$ - 1] == ' '))
                cleaned = cleaned[0 .. $ - 1];

            bool hasLetter = false;
            foreach (character; cleaned)
            {
                if (!isDigit(character))
                {
                    hasLetter = true;
                    break;
                }
            }

            if (hasLetter && !cleaned.canFind(' '))
                result ~= cleaned;
        }

        return result.length > 0 ? result : [value];
    }

    private static string headOf(CompletionRequest request)
    {
        if (request.character <= 0 || request.character >= request.currentLine.length)
            return request.currentLine;

        return request.currentLine[0 .. request.character];
    }

    private static string lastMeaningfulLine(CompletionRequest request)
    {
        foreach_reverse (line; request.previousLines)
        {
            if (line.strip.length > 0)
                return line;
        }

        return "";
    }
}

enum PromptStyle
{
    fim,
    instruct
}

struct PromptOptions
{
    PromptStyle style = PromptStyle.fim;
    string fimPrefixToken = "<|fim_prefix|>";
    string fimSuffixToken = "<|fim_suffix|>";
    string fimMiddleToken = "<|fim_middle|>";
    string instruction = "Complete the code at the cursor marker. Return only the code.";
    size_t prefixLines = 60;
    size_t suffixLines = 24;
    bool includeLanguage = true;
    bool includePath = true;
    size_t maxChars = 12000;
}

struct MergeOptions
{
    string prefix;
    string suffix;
    bool acceptSingleLine = true;
    bool acceptMultiLine = true;
    size_t maxLines = 16;
    bool insideString = false;
    bool insideComment = false;
    size_t prefixTolerance = 60;
}

struct MergeResult
{
    CompletionItem[] items;
    string inlineText;
    string source;
    size_t acceptedLines;
    bool rejected;
    string rejectReason;
    int overlap;
}

private immutable string[] driftMarkers = [
    "```", "~~~", "</html>", "</body>", "#!/usr/bin", "http://localhost",
    "TODO:", "FIXME:", "console.log(\"", "print(\""
];

string buildModelPrompt(CompletionRequest request, PromptOptions options)
{
    size_t prefixCount = options.prefixLines < request.previousLines.length
        ? options.prefixLines
        : request.previousLines.length;

    size_t suffixCount = options.suffixLines < request.nextLines.length
        ? options.suffixLines
        : request.nextLines.length;

    string[] prefixBlock = request.previousLines[request.previousLines.length - prefixCount .. $];
    string[] suffixBlock = request.nextLines[0 .. suffixCount];

    string head = request.currentLine.length > 0 && request.character <= request.currentLine.length
        ? request.currentLine[0 .. request.character]
        : request.currentLine;

    string prefixText = joinLines(prefixBlock) ~ (prefixBlock.length > 0 ? "\n" : "") ~ head;
    string suffixText = joinLines(suffixBlock);

    final switch (options.style)
    {
        case PromptStyle.fim:
            return options.fimPrefixToken ~ prefixText
                ~ options.fimSuffixToken ~ suffixText
                ~ options.fimMiddleToken;

        case PromptStyle.instruct:
            string[] header;

            if (options.includePath)
                header ~= "file: " ~ request.filePath;

            if (options.includeLanguage)
                header ~= "language: " ~ request.languageId;

            header ~= options.instruction;
            header ~= "";
            header ~= "```" ~ request.languageId;

            return joinLines(header) ~ "\n" ~ prefixText ~ "\n" ~ options.fimMiddleToken
                ~ (suffixText.length > 0 ? "\n" ~ suffixText : "");
    }
}

MergeResult mergeSuggestions(CompletionItem[] local, string generated, MergeOptions options)
{
    MergeResult result;
    result.items = local;
    result.source = "local";

    string candidate = sanitize(generated, options);

    if (candidate.length == 0)
    {
        result.rejected = true;
        result.rejectReason = "empty or drifted generation";
        return result;
    }

    int overlap = commonPrefixLength(candidate, options.prefix);

    if (options.prefix.length > 0)
    {
        bool accepted = candidate.startsWith(options.prefix);

        if (!accepted && options.prefix.length > 0)
        {
            size_t floor = options.prefix.length * options.prefixTolerance / 100;
            accepted = overlap >= floor;
        }

        if (!accepted)
        {
            result.rejected = true;
            result.rejectReason = "generation does not continue the typed prefix";
            return result;
        }
    }

    string continuation = candidate.startsWith(options.prefix) ? candidate[options.prefix.length .. $] : candidate;
    continuation = continuation.stripRight();

    if (continuation.length == 0)
    {
        result.rejected = true;
        result.rejectReason = "generation adds no new text";
        return result;
    }

    size_t lineCount = countLines(continuation);
    bool singleLine = lineCount <= 1;

    if (singleLine && !options.acceptSingleLine)
    {
        result.rejected = true;
        result.rejectReason = "single line completion rejected by policy";
        return result;
    }

    if (!singleLine && (!options.acceptMultiLine || options.insideString))
    {
        continuation = firstLine(continuation);
        lineCount = 1;
    }

    if (!singleLine && lineCount > options.maxLines)
        continuation = truncateLines(continuation, options.maxLines);

    CompletionItem model;
    model.label = firstLine(continuation).strip.length > 0 ? firstLine(continuation).strip : "suggestion";
    model.text = continuation;
    model.detail = options.insideString ? "ai string completion" : "ai multi line completion";
    model.kind = "ai";
    model.documentation = "galaxy model suggestion";
    model.score = 5000 + cast(int) lineCount * 8 + overlap;
    model.inline = true;

    CompletionItem[] merged = [model] ~ local;
    result.items = dedupeItems(merged);
    result.inlineText = continuation;
    result.source = "ai";
    result.acceptedLines = countLines(continuation);
    result.overlap = overlap;

    return result;
}

private static CompletionItem[] dedupeItems(CompletionItem[] items)
{
    CompletionItem[] result;
    bool[string] seen;

    foreach (item; items)
    {
        if (item.label.length == 0 || item.label in seen)
            continue;

        seen[item.label] = true;
        result ~= item;
    }

    sort!((a, b) => a.score > b.score)(result);

    return result;
}

private static string sanitize(string generated, MergeOptions options)
{
    string text = generated;

    size_t fence = text.canFind("```");
    if (fence > 0)
        text = text[0 .. fence];

    foreach (marker; driftMarkers)
    {
        size_t position = text.canFind(marker);

        if (position > 0)
            text = text[0 .. position];
    }

    string[] lines = splitLines(text);
    string[] kept;

    foreach (index, line; lines)
    {
        if (index > 0 && line.strip.length == 0 && kept.length > 0 && kept[$ - 1].strip.length == 0)
            break;

        if (duplicates(kept, line))
            break;

        if (index > 0 && line.strip.length == 0 && kept.length >= options.maxLines)
            break;

        kept ~= line;
    }

    string result = joinLines(kept);

    if (options.insideString && result.canFind('"') && !options.prefix.canFind('"'))
        result = result[0 .. result.canFind('"')];

    return result.stripRight();
}

private static bool duplicates(string[] existing, string line)
{
    string trimmed = line.strip;

    if (trimmed.length < 4)
        return false;

    foreach (candidate; existing)
    {
        if (candidate.strip == trimmed)
            return true;
    }

    return false;
}

private static int commonPrefixLength(string left, string right)
{
    size_t limit = left.length < right.length ? left.length : right.length;
    size_t index = 0;

    while (index < limit && left[index] == right[index])
        index++;

    return cast(int) index;
}

private static size_t countLines(string text)
{
    if (text.length == 0)
        return 0;

    return splitLines(text).length;
}

private static string firstLine(string text)
{
    auto lines = splitLines(text);
    return lines.length > 0 ? lines[0] : "";
}

private static string truncateLines(string text, size_t limit)
{
    auto lines = splitLines(text);

    if (lines.length <= limit)
        return text;

    return joinLines(lines[0 .. limit]);
}

private static string joinLines(string[] lines)
{
    string result;

    foreach (index, line; lines)
    {
        if (index > 0)
            result ~= "\n";

        result ~= line;
    }

    return result;
}

private static LanguageProfile[] buildProfiles()
{
    LanguageProfile[] profiles;

    LanguageProfile universal;
    universal.language = "*";
    universal.keywords = [
        "break", "case", "catch", "continue", "default", "do", "else", "false",
        "final", "finally", "for", "if", "in", "new", "null", "return",
        "switch", "this", "throw", "true", "try", "while"
    ];
    universal.functions = ["assert", "print", "println"];
    universal.types = ["array", "bool", "float", "int", "map", "string", "void"];
    profiles ~= universal;

    LanguageProfile d;
    d.language = "d";
    d.keywords = universal.keywords ~ [
        "alias", "abstract", "align", "asm", "auto", "cast", "const",
        "delegate", "deprecated", "enum", "export", "extern", "final",
        "foreach", "function", "goto", "immutable", "import", "inout",
        "interface", "invariant", "is", "lazy", "macro", "mixin", "module",
        "nothrow", "override", "package", "pragma", "private", "protected",
        "public", "pure", "ref", "scope", "shared", "static", "struct",
        "super", "template", "this", "typeid", "typedef", "union",
        "unittest", "version", "volatile", "with", "in", "out"
    ];
    d.functions = [
        "assert", "assertThrown", "enforce", "enforceExclusive", "freeze",
        "isNaN", "isInfinity", "min", "max", "swap", "writeln", "writefln",
        "readln", "write", "format", "chomp"
    ];
    d.types = [
        "bool", "byte", "cdouble", "cent", "cfloat", "char", "creal",
        "dchar", "double", "float", "idouble", "ifloat", "int", "ireal",
        "long", "real", "short", "size_t", "string", "ubyte", "ucent",
        "uint", "ulong", "union", "ushort", "void", "wchar", "dstring",
        "wstring", "auto"
    ];
    d.modules = [
        "std.algorithm", "std.array", "std.ascii", "std.conv", "std.datetime",
        "std.exception", "std.file", "std.format", "std.json", "std.math",
        "std.path", "std.process", "std.range", "std.regex", "std.stdio",
        "std.string", "std.traits", "std.uri", "std.http.client"
    ];
    d.snippets = [
        Snippet("writeln", "writeln(<cursor>)", "Print to stdout with newline"),
        Snippet("foreach", "foreach (<name>; <range>)", "Range based loop"),
        Snippet("struct", "struct <Name>\n{\n\t<indent><cursor>\n}", "Aggregate type"),
        Snippet("class", "class <Name>\n{\n\t<indent><cursor>\n}", "Reference type"),
        Snippet("template", "template <Name>(T)\n{\n\t<indent><cursor>\n}", "Compile time template"),
        Snippet("unittest", "unittest\n{\n\t<indent><cursor>\n}", "Unit test block"),
        Snippet("tryCatch", "try\n{\n\t<indent><cursor>\n}\ncatch (Exception e)\n{\n\t<indent>stderr.writeln(e.msg);\n}", "Exception guard"),
        Snippet("main", "int main(string[] args)\n{\n\t<indent><cursor>\n\treturn 0;\n}", "Program entry point")
    ];
    profiles ~= d;

    LanguageProfile typescript;
    typescript.language = "typescript";
    typescript.keywords = universal.keywords ~ [
        "abstract", "any", "as", "async", "await", "declare", "enum",
        "export", "extends", "implements", "infer", "interface", "keyof",
        "namespace", "never", "private", "protected", "public", "readonly",
        "satisfies", "static", "type", "typeof", "unknown", "abstract"
    ];
    typescript.functions = [
        "Array.from", "Array.isArray", "Object.assign", "Object.entries",
        "Object.keys", "Object.values", "JSON.parse", "JSON.stringify",
        "console.error", "console.info", "console.log", "console.warn",
        "setTimeout", "setInterval", "clearTimeout", "fetch", "parseInt",
        "parseFloat"
    ];
    typescript.types = [
        "any", "Array", "boolean", "Date", "Map", "never", "number", "object",
        "Promise", "ReadonlyArray", "Record", "RegExp", "Set", "string",
        "symbol", "unknown", "void", "Partial", "Pick", "Omit", "ReturnType",
        "Parameters", "NonNullable"
    ];
    typescript.snippets = [
        Snippet("arrow", "const <name> = (<params>) => {\n\t<indent><cursor>\n};", "Arrow function"),
        Snippet("asyncFunction", "export async function <name>(<params>) {\n\t<indent><cursor>\n}", "Exported async function"),
        Snippet("interface", "interface <Name> {\n\t<indent><cursor>\n}", "Interface declaration"),
        Snippet("typeAlias", "type <Name> = <type>;", "Type alias"),
        Snippet("forOf", "for (const <item> of <collection>) {\n\t<indent><cursor>\n}", "Iterate a collection"),
        Snippet("tryCatch", "try {\n\t<indent><cursor>\n} catch (error) {\n\t<indent>console.error(error);\n}", "Error handling"),
        Snippet("reactComponent", "export const <Name>: React.FC = () => {\n\t<indent>return (<cursor></>);\n};", "React function component")
    ];
    profiles ~= typescript;

    LanguageProfile javascript = typescript;
    javascript.language = "javascript";
    javascript.keywords = javascript.keywords ~ ["var", "let", "const"];
    profiles ~= javascript;

    LanguageProfile python;
    python.language = "python";
    python.keywords = [
        "and", "as", "assert", "async", "await", "break", "class", "continue",
        "def", "del", "elif", "else", "except", "finally", "for", "from",
        "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
        "or", "pass", "raise", "return", "try", "while", "with", "yield"
    ];
    python.functions = [
        "abs", "all", "any", "dict", "enumerate", "filter", "getattr", "hasattr",
        "len", "list", "map", "max", "min", "open", "print", "range", "reversed",
        "set", "setattr", "sorted", "str", "sum", "super", "tuple", "type", "zip"
    ];
    python.types = [
        "bool", "bytes", "complex", "dict", "float", "frozenset", "int", "list",
        "object", "set", "str", "tuple", "type"
    ];
    python.snippets = [
        Snippet("def", "def <name>(<params>):\n\t<indent><cursor>", "Function definition"),
        Snippet("classDef", "class <Name>:\n\t<indent>def __init__(self<params>):\n\t<indent><cursor>", "Class with initializer"),
        Snippet("forLoop", "for <item> in <collection>:\n\t<indent><cursor>", "Loop over a collection"),
        Snippet("withOpen", "with open(<path>) as handle:\n\t<indent><cursor>", "Context managed file access"),
        Snippet("ifMain", "if __name__ == \"__main__\":\n\t<indent><cursor>", "Entry point guard")
    ];
    profiles ~= python;

    LanguageProfile rust;
    rust.language = "rust";
    rust.keywords = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn",
        "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
        "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "static", "struct", "super", "trait", "true", "type", "unsafe",
        "use", "where", "while"
    ];
    rust.functions = [
        "format", "println", "print", "vec", "panic", "assert", "assert_eq",
        "unwrap", "expect", "Some", "None", "Ok", "Err"
    ];
    rust.types = [
        "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "isize", "str",
        "String", "u8", "u16", "u32", "u64", "usize", "Vec", "Option", "Result",
        "Box", "Rc", "Arc", "HashMap", "HashSet"
    ];
    rust.snippets = [
        Snippet("main", "fn main() {\n\t<indent><cursor>\n}", "Entry point"),
        Snippet("structDef", "struct <Name> {\n\t<indent><cursor>\n}", "Struct definition"),
        Snippet("implBlock", "impl <Name> {\n\t<indent><cursor>\n}", "Implementation block"),
        Snippet("matchArm", "match <value> {\n\t<indent><pattern> => <cursor>,\n}", "Match expression")
    ];
    profiles ~= rust;

    LanguageProfile go;
    go.language = "go";
    go.keywords = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else",
        "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
        "map", "package", "range", "return", "select", "struct", "switch", "type",
        "var"
    ];
    go.functions = ["append", "cap", "close", "copy", "delete", "len", "make", "new", "panic", "recover"];
    go.types = ["bool", "byte", "complex64", "error", "float32", "float64", "int", "int32", "int64", "rune", "string", "uint", "uint8", "uint64"];
    go.snippets = [
        Snippet("main", "func main() {\n\t<indent><cursor>\n}", "Program entry point"),
        Snippet("errCheck", "if err != nil {\n\t<indent>return <cursor>\n}", "Error branch"),
        Snippet("forRange", "for <key>, <value> := range <collection> {\n\t<indent><cursor>\n}", "Range loop")
    ];
    profiles ~= go;

    LanguageProfile native;
    native.language = "c";
    native.keywords = universal.keywords ~ [
        "auto", "const", "extern", "inline", "register", "restrict",
        "signed", "sizeof", "static", "struct", "typedef", "union",
        "unsigned", "volatile"
    ];
    native.functions = [
        "calloc", "fclose", "fopen", "fprintf", "free", "fscanf", "malloc",
        "memcpy", "memset", "printf", "puts", "realloc", "scanf", "snprintf",
        "sprintf", "strcat", "strchr", "strcmp", "strcpy", "strlen", "strncmp"
    ];
    native.types = [
        "bool", "char", "const char", "double", "float", "int", "long", "short",
        "signed char", "size_t", "unsigned", "void", "wchar_t"
    ];
    native.snippets = [
        Snippet("main", "int main(void)\n{\n\t<indent><cursor>\n\treturn 0;\n}", "Entry point"),
        Snippet("forLoop", "for (size_t i = 0; i < <count>; i++) {\n\t<indent><cursor>\n}", "Indexed loop"),
        Snippet("ifDebug", "#ifdef DEBUG\n<indent><cursor>\n#endif", "Conditional compilation")
    ];
    profiles ~= native;

    LanguageProfile cpp;
    cpp.language = "cpp";
    cpp.keywords = native.keywords ~ [
        "class", "constexpr", "delete", "explicit", "friend", "mutable",
        "namespace", "new", "noexcept", "nullptr", "operator", "private",
        "protected", "public", "template", "typename", "using", "virtual"
    ];
    cpp.functions = native.functions ~ ["std::cout", "std::cerr", "std::endl", "std::move", "std::vector"];
    cpp.types = native.types ~ ["auto", "bool", "std::string", "std::vector", "size_t", "nullptr_t"];
    cpp.snippets = [
        Snippet("classDef", "class <Name>\n{\npublic:\n\t<indent><cursor>\n};", "Class declaration"),
        Snippet("forRange", "for (auto &<item> : <collection>) {\n\t<indent><cursor>\n}", "Range based loop"),
        Snippet("templateFn", "template <typename T>\nT <name>(T value) {\n\t<indent>return <cursor>;\n}", "Function template")
    ];
    profiles ~= cpp;

    LanguageProfile java;
    java.language = "java";
    java.keywords = [
        "abstract", "assert", "boolean", "break", "case", "catch", "char",
        "class", "const", "continue", "default", "do", "double", "else",
        "enum", "extends", "final", "finally", "float", "for", "if",
        "implements", "import", "instanceof", "int", "interface", "long",
        "native", "new", "package", "private", "protected", "public",
        "return", "short", "static", "strictfp", "super", "switch",
        "synchronized", "this", "throw", "throws", "transient", "try",
        "var", "void", "volatile", "while"
    ];
    java.functions = ["equals", "hashCode", "toString", "println", "format", "requireNonNull"];
    java.types = ["boolean", "byte", "char", "double", "float", "int", "long", "short", "String", "var", "void", "List", "Map", "Set", "Optional"];
    java.snippets = [
        Snippet("classDef", "public class <Name> {\n\t<indent><cursor>\n}", "Class declaration"),
        Snippet("main", "public static void main(String[] args) {\n\t<indent><cursor>\n}", "Entry point"),
        Snippet("forLoop", "for (int i = 0; i < <count>; i++) {\n\t<indent><cursor>\n}", "Indexed loop")
    ];
    profiles ~= java;

    LanguageProfile json;
    json.language = "json";
    json.keywords = ["true", "false", "null"];
    json.functions = [];
    json.types = ["object", "array", "string", "number", "integer", "boolean", "null"];
    profiles ~= json;

    LanguageProfile markup;
    markup.language = "html";
    markup.keywords = [];
    markup.functions = [];
    markup.types = ["div", "span", "section", "header", "footer", "main", "nav", "aside", "article", "template", "script", "style"];
    profiles ~= markup;

    LanguageProfile style;
    style.language = "css";
    style.keywords = ["important", "inherit", "initial", "unset", "auto", "none"];
    style.functions = [];
    style.types = ["flex", "grid", "block", "inline-block", "absolute", "relative", "sticky", "fixed"];
    profiles ~= style;

    return profiles;
}

private static MemberGroup[] buildMembers()
{
    MemberGroup[] groups;

    groups ~= MemberGroup("std.stdio", [
        "stdin", "stdout", "stderr", "readln", "writeln", "writef", "writefln",
        "write", "readf", "scan", "scanln", "gets", "put", "get", "flush",
        "lockStderr", "unlockStderr"
    ]);

    groups ~= MemberGroup("stdout", [
        "write", "writef", "writefln", "writeln", "flush", "lock", "unlock"
    ]);

    groups ~= MemberGroup("stderr", [
        "write", "writef", "writefln", "writeln", "flush", "lock", "unlock"
    ]);

    groups ~= MemberGroup("stdin", ["readln", "readf", "byLine", "byLineCopy"]);

    groups ~= MemberGroup("std.array", ["append", "join", "pop", "push", "sort"]);

    groups ~= MemberGroup("std.conv", ["to", "parse", "text"]);

    groups ~= MemberGroup("std.string", ["startsWith", "endsWith", "indexOf", "strip", "split", "representation"]);

    groups ~= MemberGroup("std.algorithm", ["canFind", "filter", "map", "sort", "reduce", "count"]);

    groups ~= MemberGroup("std.json", ["parseJSON", "JSONValue", "JSONType"]);

    groups ~= MemberGroup("std.exception", ["enforce", "assertThrown", "collectException"]);

    groups ~= MemberGroup("std.path", ["buildNormalizedPath", "dirName", "baseName", "extension"]);

    groups ~= MemberGroup("std.file", ["read", "readText", "write", "writeText", "exists"]);

    groups ~= MemberGroup("std.process", ["execute", "executeShell", "environment"]);

    groups ~= MemberGroup("console", [
        "assert", "clear", "count", "debug", "dir", "error", "group", "info",
        "log", "table", "time", "timeEnd", "trace", "warn"
    ]);

    groups ~= MemberGroup("document", [
        "body", "cookie", "createElement", "createTextNode", "doctype",
        "documentElement", "getElementById", "getElementsByClassName",
        "getElementsByTagName", "head", "querySelector", "querySelectorAll",
        "title", "write"
    ]);

    groups ~= MemberGroup("document.body", [
        "appendChild", "classList", "children", "className", "id", "innerHTML",
        "innerText", "remove", "style", "textContent"
    ]);

    groups ~= MemberGroup("Math", ["abs", "ceil", "floor", "max", "min", "pow", "random", "round", "sqrt"]);

    groups ~= MemberGroup("Object", ["assign", "defineProperty", "entries", "freeze", "fromEntries", "keys", "values"]);

    groups ~= MemberGroup("Array", ["at", "concat", "entries", "every", "filter", "find", "flat", "forEach", "includes", "join", "keys", "map", "push", "reduce", "slice", "sort", "some", "splice", "values"]);

    groups ~= MemberGroup("JSON", ["parse", "stringify"]);

    groups ~= MemberGroup("Promise", ["all", "allSettled", "any", "catch", "finally", "race", "reject", "resolve", "then"]);

    groups ~= MemberGroup("self", ["close", "print", "writeln"]);

    return groups;
}