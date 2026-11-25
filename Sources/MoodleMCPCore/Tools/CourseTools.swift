import CryptoKit
import Foundation

/// course_contents and file_download.
extension MoodleTools {

    /// The course's sections and modules as one list in course order: each section, then
    /// its modules. A section's place in the list is its own entry, so a page can end
    /// inside a section and the next one start there.
    func courseContents(_ arguments: Arguments) async throws(MoodleError) -> String {
        let courseID = try arguments.requiredIdentifier("courseid")
        let moduleID = try arguments.optionalIdentifier("cmid")
        let sectionID = try arguments.optionalIdentifier("sectionid")
        let page = try arguments.page(
            defaultLimit: moduleID == nil ? ToolCatalog.defaultEntryLimit : ToolCatalog.defaultFileLimit,
            limits: ToolCatalog.entryLimitRange)
        let window = try arguments.window()
        guard moduleID == nil || sectionID == nil else {
            throw .badArgument(name: "sectionid", reason: "pass cmid or sectionid, not both.")
        }
        try session.scope.validate(courseID)
        let course = try await session.course(courseID)
        let sections = try await session.contents(of: courseID, refresh: true)
        let heading: Out = .object(["id": .int(courseID), "fullname": course?.fullname.map(Out.string) ?? .null])

        if let sectionID {
            guard let section = sections.array.first(where: { $0["id"].int == sectionID }) else {
                throw .badArgument(name: "sectionid", reason: "course \(courseID) has no section \(sectionID). Call course_contents.")
            }
            return Rows.one(
                Self.section(section), characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                notices: arguments.notices
            ) { .object(["course": heading, "section": $0]) }
        }

        if let moduleID {
            for section in sections.array {
                guard let module = section["modules"].array.first(where: { $0["id"].int == moduleID }) else { continue }
                return Self.oneModule(
                    module, section: section, heading: heading, page: page, window: window, notices: arguments.notices)
            }
            throw .badArgument(name: "cmid", reason: "course \(courseID) has no module \(moduleID). Call course_contents.")
        }

        var entries: [Out?] = []
        for section in sections.array {
            entries.append(Self.section(section))
            for module in section["modules"].array {
                entries.append(Self.module(module, section: section, files: ToolCatalog.filesPerModule))
            }
        }
        return Rows.page(
            Array(entries.dropFirst(page.offset)), offset: page.offset, limit: page.limit,
            extent: .total(entries.count), things: "entries", notices: arguments.notices,
            readOne: [
                "summary": "course_contents, passing its sectionid", "summary_html": "course_contents, passing its sectionid",
                "description": "course_contents, passing its cmid", "description_html": "course_contents, passing its cmid",
            ],
            extra: { shown in
                let unshown = shown.reduce(0) { sum, entry in
                    guard case .object(let fields) = entry, case .int(let count)? = fields["file_count"],
                        case .array(let files)? = fields["files"]
                    else { return sum }
                    return sum + count - files.count
                }
                return unshown > 0
                    ? [Notice.notShown(count: unshown, things: "files of the modules on this page", pass: "cmid=<the module's id>")]
                    : []
            }
        ) { .object(["course": heading, "entries": .array($0)]) }
    }

    /// One module with its description windowed and its files paged.
    private static func oneModule(
        _ module: JSON, section: JSON, heading: Out, page: (limit: Int, offset: Int),
        window: (characterOffset: Int, maxCharacters: Int), notices: [String]
    ) -> String {
        let files = module["contents"].array.map(file)
        return ToolStandard.fitting(page.limit) { size in
            let shown = Array(files.dropFirst(page.offset).prefix(size))
            var lines = notices
            if let position = Notice.page(offset: page.offset, count: shown.count, total: files.count, things: "files") {
                lines.append(position)
            }
            var row = Self.moduleFields(module, section: section)
            row["file_count"] = .int(files.count)
            row["files"] = .array(shown)
            return Rows.one(
                .object(row), characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                notices: lines
            ) { .object(["course": heading, "module": $0]) }
        }
    }

    static func section(_ section: JSON) -> Out {
        var row: [String: Out] = [
            "kind": .string("section"), "id": .int(section["id"]), "section": .int(section["section"]),
            "name": .str(section["name"]), "visible": .bool(section["visible"]),
            "module_count": .int(section["modules"].array.count),
        ]
        Out.html(section["summary"], into: &row, key: "summary")
        return .object(row)
    }

    /// Completion states from `completiondata.state`.
    static let completionStates = [0: "incomplete", 1: "complete", 2: "complete_pass", 3: "complete_fail"]

    /// A module entry of a listing, with at most `files` of its files.
    static func module(_ module: JSON, section: JSON, files limit: Int) -> Out {
        var row = moduleFields(module, section: section)
        let files = module["contents"].array
        row["file_count"] = .int(files.count)
        row["files"] = .array(files.prefix(limit).map(file))
        return .object(row)
    }

    static func moduleFields(_ module: JSON, section: JSON) -> [String: Out] {
        var row: [String: Out] = [
            "kind": .string("module"), "section": .int(section["section"]),
            "id": .int(module["id"]), "instance": .int(module["instance"]), "type": .str(module["modname"]),
            "name": .str(module["name"]), "visible": .bool(module["visible"]),
            "available_to_you": .bool(module["uservisible"]), "url": .url(module["url"]),
            "dates": .array(module["dates"].array.map { date in
                .object(["label": .str(date["label"]), "date": .date(date["timestamp"])])
            }),
        ]
        Out.html(module["description"], into: &row, key: "description")
        let completion = module["completiondata"]
        if completion.isNull {
            row["completion"] = .null
        } else {
            row["completion"] = .object([
                "state": completion["state"].int.flatMap { completionStates[$0] }.map(Out.string) ?? .null,
                "completed_at": .date(completion["timecompleted"]),
                "automatic": .bool(completion["isautomatic"]),
            ])
        }
        return row
    }

    static func file(_ content: JSON) -> Out {
        .object([
            "kind": .str(content["type"]), "filename": .str(content["filename"]),
            "size_bytes": .int(content["filesize"]), "modified": .date(content["timemodified"]),
            "mimetype": .str(content["mimetype"]), "url": .url(content["fileurl"]),
        ])
    }

    // MARK: file_download

    /// The one tool that writes, and only under `~/Downloads/moodle-mcp/<course>/`.
    func fileDownload(_ arguments: Arguments) async throws(MoodleError) -> String {
        let courseID = try arguments.requiredIdentifier("courseid")
        let raw = try arguments.requiredString("url")
        try session.scope.validate(courseID)
        guard let url = URL(string: raw) else {
            throw .badArgument(name: "url", reason: "'\(ToolStandard.echo(raw))' is not a URL.")
        }

        // The file must belong to a module of this course: its pluginfile context must be
        // one of the course's module contexts. Host and path are checked first so nothing
        // but this site's pluginfile.php ever receives the token.
        guard let contextID = MoodleClient.pluginfileContext(of: url, site: session.client.siteURL) else {
            throw .badArgument(name: "url", reason: "only file URLs of this Moodle site (…/pluginfile.php/…) can be downloaded.")
        }
        let index = try await session.moduleIndex()
        guard index.byContext[contextID] == courseID else {
            throw .badArgument(name: "url", reason: "that file does not belong to a module of course \(courseID).")
        }

        let data = try await session.client.downloadFile(url)
        let course = try await session.course(courseID)
        let folder = downloadsRoot.appendingPathComponent(
            Self.safeName(course?.shortname ?? "") ?? String(courseID), isDirectory: true)
        let name = Self.safeName(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent) ?? "file"
        let saved = try Self.save(data, named: name, in: folder)
        return try Output.json(Out.object([
            "path": .string(saved.path), "size_bytes": .int(data.count),
            "sha256": .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()),
            "already_present": .bool(saved.existing),
        ]))
    }

    /// A single path component: no separators, no leading dot, nothing a shell or Finder
    /// would mistake for structure.
    static func safeName(_ raw: String) -> String? {
        let cleaned = raw.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" || scalar.properties.generalCategory == .control { return "_" }
            return Character(scalar)
        }
        var name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        // APFS allows 255 bytes per name; leave room for a " (999)" suffix. Cut by whole
        // characters so a multi-byte one is never split.
        while name.utf8.count > 240 { name.removeLast() }
        return name.isEmpty ? nil : name
    }

    /// Never overwrites: an identical file already there is reported, a different one gets
    /// a numbered name.
    static func save(_ data: Data, named name: String, in folder: URL) throws(MoodleError) -> (path: String, existing: Bool) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            for number in 1...999 {
                let candidate = number == 1 ? name : "\(base) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")
                let target = folder.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: target.path) {
                    if (try? Data(contentsOf: target)) == data { return (target.path, true) }
                    continue
                }
                try data.write(to: target, options: .withoutOverwriting)
                return (target.path, false)
            }
        } catch {
            throw .configuration("The file could not be written under \(folder.path).")
        }
        throw .configuration("Too many files named \(name) under \(folder.path).")
    }
}
