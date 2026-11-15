import CryptoKit
import Foundation

/// course_contents and file_download.
extension MoodleTools {

    func courseContents(_ arguments: Arguments) async throws(MoodleError) -> String {
        let courseID = try arguments.requiredInt("courseid")
        try session.scope.validate(courseID)
        let course = try await session.course(courseID)
        let sections = try await session.contents(of: courseID, refresh: true)
        let rendered: [Out] = sections.array.map { section in
            var row: [String: Out] = [
                "id": .int(section["id"]), "section": .int(section["section"]), "name": .str(section["name"]),
                "visible": .bool(section["visible"]),
                "modules": .array(section["modules"].array.map(Self.module)),
            ]
            Out.html(section["summary"], into: &row, key: "summary")
            return .object(row)
        }
        return try Output.json(Out.object([
            "course": .object(["id": .int(courseID), "fullname": course?.fullname.map(Out.string) ?? .null]),
            "sections": .array(rendered),
        ]))
    }

    /// Completion states from `completiondata.state`.
    static let completionStates = [0: "incomplete", 1: "complete", 2: "complete_pass", 3: "complete_fail"]

    static func module(_ module: JSON) -> Out {
        var row: [String: Out] = [
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
        row["files"] = .array(module["contents"].array.map { content in
            .object([
                "kind": .str(content["type"]), "filename": .str(content["filename"]),
                "size_bytes": .int(content["filesize"]), "modified": .date(content["timemodified"]),
                "mimetype": .str(content["mimetype"]), "url": .url(content["fileurl"]),
            ])
        })
        return .object(row)
    }

    // MARK: file_download

    /// The one tool that writes, and only under `~/Downloads/moodle-mcp/<course>/`.
    func fileDownload(_ arguments: Arguments) async throws(MoodleError) -> String {
        let courseID = try arguments.requiredInt("courseid")
        try session.scope.validate(courseID)
        guard let raw = try arguments.string("url"), let url = URL(string: raw) else { throw .missingArgument("url") }

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
