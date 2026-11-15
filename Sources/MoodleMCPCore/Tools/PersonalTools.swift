import Foundation

/// grades_get and profile_get.
extension MoodleTools {

    func grades(_ arguments: Arguments) async throws(MoodleError) -> String {
        let courseID = try arguments.requiredInt("courseid")
        try session.scope.validate(courseID)
        let userID = try await session.userID()
        let answer = try await session.client.callJSON(.gradeItems, [.int("courseid", courseID), .int("userid", userID)])
        let report = answer["usergrades"].array.first { $0["courseid"].int == courseID && $0["userid"].int == userID }
        let rows: [Out] = (report?["gradeitems"].array ?? []).map { item in
            var row: [String: Out] = [
                "id": .int(item["id"]),
                "name": item["itemtype"].string == "course" && item["itemname"].isNull ? .string("Course total") : .str(item["itemname"]),
                "type": .str(item["itemtype"]), "module": .str(item["itemmodule"]), "cmid": .int(item["cmid"]),
                "grade": .str(item["gradeformatted"]), "grade_raw": .number(item["graderaw"]),
                "range": .str(item["rangeformatted"]), "min": .number(item["grademin"]), "max": .number(item["grademax"]),
                "percentage": .str(item["percentageformatted"]), "weight": .str(item["weightformatted"]),
                "submitted": .date(item["gradedatesubmitted"]), "graded": .date(item["gradedategraded"]),
            ]
            Out.html(item["feedback"], into: &row, key: "feedback")
            return .object(row)
        }
        return try Output.json(Out.object(["courseid": .int(courseID), "items": .array(rows)]))
    }

    /// Only the custom profile fields and the city. Moodle sends much more (email,
    /// address, phone, preferences); none of it is decoded into the answer.
    func profile() async throws(MoodleError) -> String {
        let userID = try await session.userID()
        let answer = try await session.client.callJSON(
            .usersByField, [.value("field", "id"), .list("values", [String(userID)])])
        guard let user = answer.array.first(where: { $0["id"].int == userID }) else {
            throw .unexpectedResponse("core_user_get_users_by_field did not return the token's user.")
        }
        let fields: [Out] = user["customfields"].array.map { field in
            let display = field["displayvalue"].string ?? field["value"].string
            return .object([
                "shortname": .str(field["shortname"]), "name": .str(field["name"]),
                "value": display.map { .string(HTMLText.plain($0)) } ?? .null,
            ])
        }
        return try Output.json(Out.object(["city": .str(user["city"]), "custom_fields": .array(fields)]))
    }
}
