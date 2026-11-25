import Foundation

/// The long texts of a row: what Moodle lets a person write at length (a summary, an
/// introduction, a message, feedback, a profile field), each as plain text and, beside it,
/// as the HTML it came in. A listing clips them; a tool reading one item windows them.
enum LongText {

    static let keys: Set<String> = {
        let plain = ["summary", "description", "intro", "message", "text", "feedback", "display"]
        return Set(plain + plain.map { $0 + "_html" } + ["value"])
    }()

    /// `value` with every long text shortened to `width` characters. `clipped` gains the
    /// path of each field that was in fact shortened, once, in the order met.
    static func clip(_ value: Out, width: Int, path: String = "", clipped: inout [String]) -> Out {
        switch value {
        case .object(let fields):
            var result: [String: Out] = [:]
            for key in fields.keys.sorted() {
                let field = fields[key]!
                let fieldPath = path.isEmpty ? key : "\(path).\(key)"
                if keys.contains(key), case .string(let text) = field, text.count > width {
                    result[key] = .string(String(text.prefix(width)))
                    if !clipped.contains(fieldPath) { clipped.append(fieldPath) }
                } else {
                    result[key] = clip(field, width: width, path: fieldPath, clipped: &clipped)
                }
            }
            return .object(result)
        case .array(let items):
            return .array(items.map { clip($0, width: width, path: path, clipped: &clipped) })
        default:
            return value
        }
    }

    /// `value` with every long text replaced by the window `characterOffset` characters in
    /// and at most `maxCharacters` long, the same window for each. `notices` gains, for each
    /// text the window does not hold whole, where the window sits in it.
    static func window(
        _ value: Out, characterOffset: Int, maxCharacters: Int, path: String = "", notices: inout [String]
    ) -> Out {
        switch value {
        case .object(let fields):
            var result: [String: Out] = [:]
            for key in fields.keys.sorted() {
                let field = fields[key]!
                let fieldPath = path.isEmpty ? key : "\(path).\(key)"
                if keys.contains(key), case .string(let text) = field {
                    let window = ToolStandard.window(
                        of: text, characterOffset: characterOffset, maxCharacters: maxCharacters, label: fieldPath)
                    result[key] = .string(window.text)
                    if let notice = window.notice { notices.append(notice) }
                } else {
                    result[key] = Self.window(
                        field, characterOffset: characterOffset, maxCharacters: maxCharacters, path: fieldPath,
                        notices: &notices)
                }
            }
            return .object(result)
        case .array(let items):
            return .array(items.map {
                window($0, characterOffset: characterOffset, maxCharacters: maxCharacters, path: path, notices: &notices)
            })
        default:
            return value
        }
    }
}

/// How a listing of this server says how much there is.
enum Extent {
    /// Every matching row is known: `count` of them.
    case total(Int)
    /// The source gave the rows asked for and at least one more, and no total.
    case moreAfter
    /// The source ran out: the rows given are the last ones.
    case endsHere
    /// A search stopped before the source ran out, and says so in its own notice: whether
    /// more exist is not known.
    case stopped
}

/// Renders the pages and single items of every tool here, so that each states what it
/// left out in the same words, before the JSON.
enum Rows {

    /// One page of a listing. `rows` are the rows from `offset` on, in the order the tool
    /// states: every remaining one for a listing held whole, or as many as the source gave.
    /// A `nil` row stands for one the source gave but this server never shows (it belongs
    /// to no allowed course); it takes its place in the count, and `hidden` says how many
    /// of those the page spans. Long texts are clipped to `clipWidth`, and `readOne` gives,
    /// for each field that can be clipped, the call that reads one in full.
    static func page(
        _ rows: [Out?], offset: Int, limit: Int, extent: Extent, things: String, notices: [String],
        clipWidth: Int = ToolCatalog.clipWidth, readOne: [String: String] = [:],
        hidden: ((Int) -> String)? = nil, extra: ([Out]) -> [String] = { _ in [] },
        render: ([Out]) -> Out
    ) -> String {
        ToolStandard.fitting(limit) { size in
            let span = Array(rows.prefix(size))
            var clipped: [String] = []
            let shown = span.compactMap { $0 }.map { LongText.clip($0, width: clipWidth, clipped: &clipped) }
            var lines = notices
            if let position = position(offset: offset, count: span.count, of: rows.count, extent: extent, things: things) {
                lines.append(position)
            }
            let hiddenCount = span.count - shown.count
            if hiddenCount > 0, let hidden { lines.append(hidden(hiddenCount)) }
            for field in clipped {
                let tool = readOne[field] ?? readOne[String(field.split(separator: ".").last ?? "")] ?? ""
                lines.append(Notice.clipped(field: field, width: clipWidth, tool: tool))
            }
            lines += extra(shown)
            return ToolStandard.withNotices(lines, Output.text(render(shown)))
        }
    }

    /// The sentence that places a page in the whole, or `nil` when the page is the whole.
    static func position(offset: Int, count: Int, of available: Int, extent: Extent, things: String) -> String? {
        switch extent {
        case .total(let total):
            return Notice.page(offset: offset, count: count, total: total, things: things)
        case .moreAfter:
            return Notice.page(offset: offset, count: count, total: nil, things: things)
        case .stopped:
            return count == 0 ? nil : Notice.page(offset: offset, count: count, total: nil, things: things)
        case .endsHere:
            guard available == 0, offset > 0 else {
                return Notice.page(offset: offset, count: count, total: offset + available, things: things)
            }
            // The source says only that nothing is left at this offset, not how much came
            // before it, so the total that Notice.page would quote is not known.
            return "Nothing at offset=\(offset): the \(things) end before it. That is all."
        }
    }

    /// One item read in full: its long texts windowed by `characterOffset` and
    /// `maxCharacters`, each window announced before the JSON.
    static func one(
        _ item: Out, characterOffset: Int, maxCharacters: Int, notices: [String], render: (Out) -> Out = { $0 }
    ) -> String {
        ToolStandard.fitting(maxCharacters) { size in
            var lines = notices
            let windowed = LongText.window(item, characterOffset: characterOffset, maxCharacters: size, notices: &lines)
            return ToolStandard.withNotices(lines, Output.text(render(windowed)))
        }
    }
}
