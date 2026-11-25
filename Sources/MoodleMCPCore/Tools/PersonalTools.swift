import Foundation

/// grades_get and profile_get.
extension MoodleTools {

    func grades(_ arguments: Arguments) async throws(MoodleError) -> String {
        let courseID = try arguments.requiredIdentifier("courseid")
        let itemID = try arguments.optionalIdentifier("itemid")
        let page = try arguments.page(defaultLimit: ToolCatalog.defaultGradeLimit, limits: ToolCatalog.gradeLimitRange)
        let window = try arguments.window()
        try session.scope.validate(courseID)
        let userID = try await session.userID()
        let answer = try await session.client.callJSON(.gradeItems, [.int("courseid", courseID), .int("userid", userID)])
        let report = answer["usergrades"].array.first { $0["courseid"].int == courseID && $0["userid"].int == userID }
        // Moodle's order is the grade book's, which is the order a person reads it in.
        let items = report?["gradeitems"].array ?? []
        if let itemID {
            guard let item = items.first(where: { $0["id"].int == itemID }) else {
                throw .badArgument(name: "itemid", reason: "course \(courseID) has no grade item \(itemID). Call grades_get.")
            }
            return Rows.one(
                Self.gradeItem(item), characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                notices: arguments.notices
            ) { .object(["courseid": .int(courseID), "item": $0]) }
        }
        let rows: [Out?] = items.map(Self.gradeItem)
        let readOne = "grades_get, passing its id as itemid"
        return Rows.page(
            Array(rows.dropFirst(page.offset)), offset: page.offset, limit: page.limit, extent: .total(rows.count),
            things: "grade items", notices: arguments.notices, readOne: ["feedback": readOne, "feedback_html": readOne]
        ) { .object(["courseid": .int(courseID), "items": .array($0)]) }
    }

    private static func gradeItem(_ item: JSON) -> Out {
        var row: [String: Out] = [
            "id": .int(item["id"]),
            "name": item["itemtype"].string == "course" && item["itemname"].isNull ? .string("Course total") : .str(item["itemname"]),
            "type": .str(item["itemtype"]), "module": .str(item["itemmodule"]), "cmid": .int(item["cmid"]),
            "grade": .str(item["gradeformatted"]), "grade_raw": .number(item["graderaw"]),
            "range": item["rangeformatted"].string.map { .string(HTMLText.decodeEntities($0)) } ?? .null,
            "min": .number(item["grademin"]), "max": .number(item["grademax"]),
            "percentage": .str(item["percentageformatted"]), "weight": .str(item["weightformatted"]),
            "submitted": .date(item["gradedatesubmitted"]), "graded": .date(item["gradedategraded"]),
        ]
        Out.html(item["feedback"], into: &row, key: "feedback")
        return .object(row)
    }

    /// Only the custom profile fields and the city. Moodle sends much more (email,
    /// address, phone, preferences); none of it is decoded into the answer.
    func profile(_ arguments: Arguments) async throws(MoodleError) -> String {
        let shortname = try arguments.optionalString("shortname")
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultProfileFieldLimit, limits: ToolCatalog.profileFieldLimitRange)
        let window = try arguments.window()
        let userID = try await session.userID()
        let answer = try await session.client.callJSON(
            .usersByField, [.value("field", "id"), .list("values", [String(userID)])])
        guard let user = answer.array.first(where: { $0["id"].int == userID }) else {
            throw .unexpectedResponse("core_user_get_users_by_field did not return the token's user.")
        }
        let fields = user["customfields"].array
        let city = Out.str(user["city"])
        if let shortname {
            guard let field = fields.first(where: { $0["shortname"].string == shortname }) else {
                throw .badArgument(name: "shortname", reason: "no custom field is called '\(ToolStandard.echo(shortname))'. Call profile_get.")
            }
            return Rows.one(
                Self.customField(field), characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                notices: arguments.notices
            ) { .object(["city": city, "custom_field": $0]) }
        }
        let rows: [Out?] = fields.map(Self.customField)
        return Rows.page(
            Array(rows.dropFirst(page.offset)), offset: page.offset, limit: page.limit, extent: .total(rows.count),
            things: "custom fields", notices: arguments.notices, readOne: ["value": "profile_get, passing its shortname"]
        ) { .object(["city": city, "custom_fields": .array($0)]) }
    }

    private static func customField(_ field: JSON) -> Out {
        let display = field["displayvalue"].string ?? field["value"].string
        return .object([
            "shortname": .str(field["shortname"]), "name": .str(field["name"]),
            "value": display.map { .string(HTMLText.plain($0)) } ?? .null,
        ])
    }
}
