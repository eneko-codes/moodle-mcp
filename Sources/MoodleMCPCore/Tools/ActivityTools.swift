import Foundation

/// assignments_list, quizzes_list and events_list.
extension MoodleTools {

    // MARK: assignments_list

    /// `mod_assign_get_assignments`, then `mod_assign_get_submission_status` once per
    /// assignment. Neither logs a view (checked against Moodle 4.5's source); the view
    /// logger is `mod_assign_view_submission_status`, which is forbidden.
    func assignments(_ arguments: Arguments) async throws(MoodleError) -> String {
        let courseIDs = try session.scope.resolve(try arguments.int("courseid"))
        let answer = try await session.client.callJSON(.assignments, [.ints("courseids", courseIDs)])
        var rows: [Out] = []
        for course in answer["courses"].array {
            guard let courseID = course["id"].int, session.scope.contains(courseID) else { continue }
            for assignment in course["assignments"].array {
                rows.append(try await assignmentRow(assignment, courseID: courseID))
            }
        }
        return try Output.json(Out.array(rows))
    }

    private func assignmentRow(_ assignment: JSON, courseID: Int) async throws(MoodleError) -> Out {
        var row: [String: Out] = [
            "id": .int(assignment["id"]), "cmid": .int(assignment["cmid"]), "courseid": .int(courseID),
            "name": .str(assignment["name"]),
            "opens": .date(assignment["allowsubmissionsfromdate"]), "due": .date(assignment["duedate"]),
            "cutoff": .date(assignment["cutoffdate"]), "grading_due": .date(assignment["gradingduedate"]),
            // A negative grade is a scale id in Moodle, not a maximum.
            "max_grade": (assignment["grade"].double ?? 0) < 0 ? .null : .number(assignment["grade"]),
            "intro_attachments": .array(assignment["introattachments"].array.map(Self.attachment)),
        ]
        Out.html(assignment["intro"], into: &row, key: "intro")

        guard let assignID = assignment["id"].int else { return .object(row) }
        let status = try await session.client.callJSON(.submissionStatus, [.int("assignid", assignID)])
        let submission = status["lastattempt"]["submission"]
        row["submission"] = .object([
            "status": .str(submission["status"]),
            "modified": .date(submission["timemodified"]),
            "submitted": submission["status"].string == "submitted" ? .date(submission["timemodified"]) : .null,
            "grading_status": .str(status["lastattempt"]["gradingstatus"]),
        ])
        let feedback = status["feedback"]
        if feedback.isNull {
            row["grade"] = .null
        } else {
            var grade: [String: Out] = [
                "grade": .number(feedback["grade"]["grade"]), "graded": .date(feedback["grade"]["timemodified"]),
            ]
            Out.html(feedback["gradefordisplay"], into: &grade, key: "display")
            row["grade"] = .object(grade)
        }
        return .object(row)
    }

    static func attachment(_ file: JSON) -> Out {
        .object([
            "filename": .str(file["filename"]), "size_bytes": .int(file["filesize"]),
            "modified": .date(file["timemodified"]), "url": .url(file["fileurl"].isNull ? file["url"] : file["fileurl"]),
        ])
    }

    // MARK: quizzes_list

    /// Quiz settings and your attempts' state and grade. Never questions or answers: the
    /// functions that return them (`mod_quiz_get_attempt_*`) are forbidden.
    func quizzes(_ arguments: Arguments) async throws(MoodleError) -> String {
        let courseIDs = try session.scope.resolve(try arguments.int("courseid"))
        let answer = try await session.client.callJSON(.quizzes, [.ints("courseids", courseIDs)])
        var rows: [Out] = []
        for quiz in answer["quizzes"].array {
            guard let courseID = quiz["course"].int, session.scope.contains(courseID), let quizID = quiz["id"].int else {
                continue
            }
            let maxGrade = quiz["grade"].double
            let sumGrades = quiz["sumgrades"].double
            var row: [String: Out] = [
                "id": .int(quizID), "cmid": .int(quiz["coursemodule"]), "courseid": .int(courseID),
                "name": .str(quiz["name"]), "opens": .date(quiz["timeopen"]), "closes": .date(quiz["timeclose"]),
                "time_limit_seconds": (quiz["timelimit"].int ?? 0) > 0 ? .int(quiz["timelimit"]) : .null,
                // 0 means unlimited in Moodle.
                "attempts_allowed": (quiz["attempts"].int ?? 0) > 0 ? .int(quiz["attempts"]) : .string("unlimited"),
                "max_grade": .number(quiz["grade"]),
            ]
            Out.html(quiz["intro"], into: &row, key: "intro")
            let attempts = try await session.client.callJSON(
                .quizUserAttempts, [.int("quizid", quizID), .value("status", "all"), .value("includepreviews", "0")])
            row["your_attempts"] = .array(attempts["attempts"].array.map { attempt in
                var grade: Out = .null
                if let raw = attempt["sumgrades"].double, let maxGrade, let sumGrades, sumGrades > 0 {
                    grade = .double((raw / sumGrades * maxGrade * 100).rounded() / 100)
                }
                return .object([
                    "attempt": .int(attempt["attempt"]), "state": .str(attempt["state"]),
                    "started": .date(attempt["timestart"]), "finished": .date(attempt["timefinish"]), "grade": grade,
                ])
            })
            rows.append(.object(row))
        }
        return try Output.json(Out.array(rows))
    }

    // MARK: events_list

    /// Action events (deadlines and the like) between two moments, only for allowed courses.
    func events(_ arguments: Arguments) async throws(MoodleError) -> String {
        let now = Int(Date().timeIntervalSince1970)
        let from = try arguments.string("from").map { text throws(MoodleError) in try DateArgument.parse(text, name: "from") } ?? now
        let to = try arguments.string("to").map { text throws(MoodleError) in try DateArgument.parse(text, name: "to") } ?? now + 30 * 86_400
        guard to >= from else { throw .badArgument(name: "to", reason: "is earlier than 'from'.") }
        guard !session.scope.allowed.isEmpty else { throw .noAllowedCourses }
        let names = Dictionary(uniqueKeysWithValues: try await session.allowedCourses().map { ($0.id, $0.fullname) })

        var rows: [Out] = []
        var after: Int?
        // Moodle caps a page at 50; four pages is a ceiling, reported when reached.
        var truncated = false
        for page in 0..<4 {
            var parameters: [FormParameter] = [.int("timesortfrom", from), .int("timesortto", to), .int("limitnum", 50)]
            if let after { parameters.append(.int("aftereventid", after)) }
            let answer = try await session.client.callJSON(.actionEvents, parameters)
            let events = answer["events"].array
            for event in events {
                guard let courseID = event["course"]["id"].int, session.scope.contains(courseID) else { continue }
                var row: [String: Out] = [
                    "id": .int(event["id"]), "name": .str(event["name"]), "courseid": .int(courseID),
                    "course": names[courseID].flatMap { $0 }.map(Out.string) ?? .null,
                    "module": .str(event["modulename"]), "instance": .int(event["instance"]),
                    "event_type": .str(event["eventtype"]), "date": .date(event["timesort"]),
                    "start": .date(event["timestart"]), "overdue": .bool(event["overdue"]), "url": .url(event["url"]),
                    "action": event["action"].isNull ? .null : .object([
                        "name": .str(event["action"]["name"]), "actionable": .bool(event["action"]["actionable"]),
                    ]),
                ]
                Out.html(event["description"], into: &row, key: "description")
                rows.append(.object(row))
            }
            guard events.count == 50, let last = answer["lastid"].int ?? events.last?["id"].int else { break }
            after = last
            if page == 3 { truncated = true }
        }
        return try Output.json(Out.object([
            "from": .date(from), "to": .date(to), "events": .array(rows), "truncated": .bool(truncated),
        ]))
    }
}
