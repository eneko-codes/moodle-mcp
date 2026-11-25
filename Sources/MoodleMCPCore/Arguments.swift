import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool puts `notices` before its data.
public final class Arguments {
    private let values: [String: Value]

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    /// Refuses a name the tool's schema does not list, so that a call still using a
    /// renamed argument fails instead of running as if it had not been given.
    func refuseOthers(than allowed: [String]) throws(MoodleError) {
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        guard let first = unknown.first else { return }
        throw .unknownArgument(name: first, allowed: allowed.sorted())
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    private func wholeNumber(_ name: String) throws(MoodleError) -> Int? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue else {
            throw .badArgument(name: name, reason: "a whole number was expected.")
        }
        return number
    }

    /// A quantity: a size, a count, an offset. Outside its range it is moved to the nearest
    /// allowed value, and `notices` gains the sentence that says which value was used.
    func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws(MoodleError) -> Int {
        guard let number = try wholeNumber(name) else { return fallback }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// An identifier: a course, a forum, a post. Outside its range it is refused, not
    /// moved, because the nearest allowed value would name something else.
    func optionalIdentifier(_ name: String) throws(MoodleError) -> Int? {
        guard let number = try wholeNumber(name) else { return nil }
        let range = ToolCatalog.identifierRange
        guard range.contains(number) else {
            throw .badArgument(
                name: name, reason: "a whole number from \(range.lowerBound) to \(range.upperBound) was expected.")
        }
        return number
    }

    func requiredIdentifier(_ name: String) throws(MoodleError) -> Int {
        guard let number = try optionalIdentifier(name) else { throw .missingArgument(name) }
        return number
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    func page(defaultLimit: Int, limits: ClosedRange<Int>) throws(MoodleError) -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    /// The `character_offset` and `max_characters` of the window on one item's long texts.
    func window() throws(MoodleError) -> (characterOffset: Int, maxCharacters: Int) {
        (
            try int("character_offset", default: 0, in: ToolCatalog.offsetRange),
            try int("max_characters", default: ToolCatalog.defaultMaxCharacters, in: ToolCatalog.maxCharactersRange)
        )
    }

    /// Text with surrounding white space removed; empty text is not given.
    func optionalString(_ name: String) throws(MoodleError) -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw .badArgument(name: name, reason: "text was expected.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func requiredString(_ name: String) throws(MoodleError) -> String {
        guard let text = try optionalString(name) else { throw .missingArgument(name) }
        return text
    }

    /// A moment as Unix seconds. `endOfRange` makes it the last second of the precision
    /// written: a day covers the whole day, a minute the whole minute.
    func optionalDate(_ name: String, endOfRange: Bool = false) throws(MoodleError) -> Int? {
        guard let text = try optionalString(name) else { return nil }
        return try DateArgument.parse(text, name: name, endOfRange: endOfRange)
    }
}
