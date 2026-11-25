import Foundation

/// assignments_list, quizzes_list and events_list.
extension MoodleTools {

    // MARK: assignments_list

    /// `mod_assign_get_assignments`, then `mod_assign_get_submission_status` once per
    /// assignment on the page. Neither logs a view (checked against Moodle 4.5's source);
    /// the view logger is `mod_assign_view_submission_status`, which is forbidden.
    func assignments(_ arguments: Arguments, budget: Budget) async throws(MoodleError) -> String {
        let courseID = try arguments.optionalIdentifier("courseid")
        let assignmentID = try arguments.optionalIdentifier("assignmentid")
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultAssignmentLimit, limits: ToolCatalog.assignmentLimitRange)
        let window = try arguments.window()
        let courseIDs = try session.scope.resolve(courseID)
        let answer = try await session.client.callJSON(.assignments, [.ints("courseids", courseIDs)])
        var found: [(assignment: JSON, courseID: Int)] = []
        for course in answer["courses"].array {
            guard let courseID = course["id"].int, session.scope.contains(courseID) else { continue }
            for assignment in course["assignments"].array where assignment["id"].int != nil {
                found.append((assignment, courseID))
            }
        }

        if let assignmentID {
            guard let match = found.first(where: { $0.assignment["id"].int == assignmentID }) else {
                throw .badArgument(
                    name: "assignmentid",
                    reason: "no assignment \(assignmentID) in \(courseID.map { "course \($0)" } ?? "the allowed courses"). Call assignments_list.")
            }
            let row = try await assignmentRow(match.assignment, courseID: match.courseID)
            return Rows.one(
                row, characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                notices: arguments.notices)
        }

        found.sort { Self.soonestFirst($0.assignment["duedate"].int, $0.assignment["id"].int, $1.assignment["duedate"].int, $1.assignment["id"].int) }
        var rows: [Out?] = []
        var notices = arguments.notices
        for item in found.dropFirst(page.offset).prefix(page.limit) {
            // At least one, so that a call always gets further than the last.
            if !rows.isEmpty, budget.isSpent {
                notices.append(Notice.partial(after: rows.count, things: "assignments", narrowBy: "courseid or limit"))
                break
            }
            rows.append(try await assignmentRow(item.assignment, courseID: item.courseID))
        }
        let readOne = "assignments_list, passing its assignmentid"
        return Rows.page(
            rows, offset: page.offset, limit: page.limit, extent: .total(found.count), things: "assignments",
            notices: notices,
            readOne: ["intro": readOne, "intro_html": readOne, "display": readOne, "display_html": readOne],
            render: Out.array)
    }

    /// Soonest first; no date (Moodle's 0) after every date; then by id, so no two tie.
    static func soonestFirst(_ lhsDate: Int?, _ lhsID: Int?, _ rhsDate: Int?, _ rhsID: Int?) -> Bool {
        let lhs = (lhsDate ?? 0) > 0 ? lhsDate! : Int.max
        let rhs = (rhsDate ?? 0) > 0 ? rhsDate! : Int.max
        return lhs != rhs ? lhs < rhs : (lhsID ?? 0) < (rhsID ?? 0)
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
    func quizzes(_ arguments: Arguments, budget: Budget) async throws(MoodleError) -> String {
        let courseID = try arguments.optionalIdentifier("courseid")
        let quizID = try arguments.optionalIdentifier("quizid")
        let page = try arguments.page(
            defaultLimit: quizID == nil ? ToolCatalog.defaultQuizLimit : ToolCatalog.defaultAttemptLimit,
            limits: ToolCatalog.quizLimitRange)
        let window = try arguments.window()
        let courseIDs = try session.scope.resolve(courseID)
        let answer = try await session.client.callJSON(.quizzes, [.ints("courseids", courseIDs)])
        var found = answer["quizzes"].array.filter { quiz in
            quiz["id"].int != nil && quiz["course"].int.map(session.scope.contains) == true
        }

        if let quizID {
            guard let quiz = found.first(where: { $0["id"].int == quizID }) else {
                throw .badArgument(
                    name: "quizid",
                    reason: "no quiz \(quizID) in \(courseID.map { "course \($0)" } ?? "the allowed courses"). Call quizzes_list.")
            }
            let attempts = try await self.attempts(of: quiz)
            return ToolStandard.fitting(page.limit) { size in
                let shown = Array(attempts.dropFirst(page.offset).prefix(size))
                var notices = arguments.notices
                if let position = Notice.page(offset: page.offset, count: shown.count, total: attempts.count, things: "attempts") {
                    notices.append(position)
                }
                var row = Self.quizFields(quiz)
                row["attempt_count"] = .int(attempts.count)
                row["your_attempts"] = .array(shown)
                return Rows.one(
                    .object(row), characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                    notices: notices)
            }
        }

        found.sort { Self.soonestFirst($0["timeclose"].int, $0["id"].int, $1["timeclose"].int, $1["id"].int) }
        var rows: [Out?] = []
        var notices = arguments.notices
        for quiz in found.dropFirst(page.offset).prefix(page.limit) {
            if !rows.isEmpty, budget.isSpent {
                notices.append(Notice.partial(after: rows.count, things: "quizzes", narrowBy: "courseid or limit"))
                break
            }
            let attempts = try await self.attempts(of: quiz)
            var row = Self.quizFields(quiz)
            row["attempt_count"] = .int(attempts.count)
            row["your_attempts"] = .array(Array(attempts.prefix(ToolCatalog.attemptsPerQuiz)))
            rows.append(.object(row))
        }
        let readOne = "quizzes_list, passing its quizid"
        return Rows.page(
            rows, offset: page.offset, limit: page.limit, extent: .total(found.count), things: "quizzes",
            notices: notices, readOne: ["intro": readOne, "intro_html": readOne],
            extra: { shown in
                let unshown = shown.reduce(0) { sum, row in
                    guard case .object(let fields) = row, case .int(let count)? = fields["attempt_count"],
                        case .array(let attempts)? = fields["your_attempts"]
                    else { return sum }
                    return sum + count - attempts.count
                }
                return unshown > 0
                    ? [Notice.notShown(count: unshown, things: "attempts of the quizzes on this page", pass: "quizid=<the quiz's id>")]
                    : []
            },
            render: Out.array)
    }

    private static func quizFields(_ quiz: JSON) -> [String: Out] {
        var row: [String: Out] = [
            "id": .int(quiz["id"]), "cmid": .int(quiz["coursemodule"]), "courseid": .int(quiz["course"]),
            "name": .str(quiz["name"]), "opens": .date(quiz["timeopen"]), "closes": .date(quiz["timeclose"]),
            "time_limit_seconds": (quiz["timelimit"].int ?? 0) > 0 ? .int(quiz["timelimit"]) : .null,
            // 0 means unlimited in Moodle.
            "attempts_allowed": (quiz["attempts"].int ?? 0) > 0 ? .int(quiz["attempts"]) : .string("unlimited"),
            "max_grade": .number(quiz["grade"]),
        ]
        Out.html(quiz["intro"], into: &row, key: "intro")
        return row
    }

    /// Your attempts at `quiz`, in attempt order, with the grade scaled to the quiz's.
    private func attempts(of quiz: JSON) async throws(MoodleError) -> [Out] {
        guard let quizID = quiz["id"].int else { return [] }
        let maxGrade = quiz["grade"].double
        let sumGrades = quiz["sumgrades"].double
        let answer = try await session.client.callJSON(
            .quizUserAttempts, [.int("quizid", quizID), .value("status", "all"), .value("includepreviews", "0")])
        return answer["attempts"].array
            .sorted { ($0["attempt"].int ?? 0, $0["id"].int ?? 0) < ($1["attempt"].int ?? 0, $1["id"].int ?? 0) }
            .map { attempt in
                var grade: Out = .null
                if let raw = attempt["sumgrades"].double, let maxGrade, let sumGrades, sumGrades > 0 {
                    grade = .double((raw / sumGrades * maxGrade * 100).rounded() / 100)
                }
                return .object([
                    "attempt": .int(attempt["attempt"]), "state": .str(attempt["state"]),
                    "started": .date(attempt["timestart"]), "finished": .date(attempt["timefinish"]), "grade": grade,
                ])
            }
    }

    // MARK: events_list

    /// Action events (deadlines and the like) of allowed courses, walked from the start of
    /// the range in Moodle's order (date, then id), because Moodle pages them only by the
    /// last id seen and other courses' events are dropped on the way.
    func events(_ arguments: Arguments, budget: Budget) async throws(MoodleError) -> String {
        let fromDate = try arguments.optionalDate("from_date")
        let toDate = try arguments.optionalDate("to_date", endOfRange: true)
        let eventID = try arguments.optionalIdentifier("eventid")
        let page = try arguments.page(defaultLimit: ToolCatalog.defaultEventLimit, limits: ToolCatalog.eventLimitRange)
        let window = try arguments.window()
        // With no date at all the list starts now; to_date alone runs from the earliest.
        let from = fromDate ?? (toDate == nil ? Int(Date().timeIntervalSince1970) : nil)
        if let from, let toDate, toDate < from {
            throw .badArgument(name: "to_date", reason: "is earlier than from_date.")
        }
        guard !session.scope.allowed.isEmpty else { throw .noAllowedCourses }
        let names = Dictionary(uniqueKeysWithValues: try await session.allowedCourses().map { ($0.id, $0.fullname) })

        var matched: [Out?] = []
        var scanned = 0
        var requests = 0
        var after: Int?
        var exhausted = false
        var notices = arguments.notices
        // One past the page, so that a full page knows whether more follow.
        let wanted = page.offset + page.limit + 1
        while eventID != nil || matched.count < wanted {
            if requests == ToolCatalog.scanRequests {
                notices.append(Notice.scanStopped(after: scanned, things: "events", narrowBy: "from_date and to_date"))
                break
            }
            if requests > 0, budget.isSpent {
                notices.append(Notice.partial(after: scanned, things: "events", narrowBy: "from_date and to_date"))
                break
            }
            var parameters: [FormParameter] = [.int("limitnum", ToolCatalog.eventsPerRequest)]
            if let from { parameters.append(.int("timesortfrom", from)) }
            if let toDate { parameters.append(.int("timesortto", toDate)) }
            if let after { parameters.append(.int("aftereventid", after)) }
            let answer = try await session.client.callJSON(.actionEvents, parameters)
            requests += 1
            let events = answer["events"].array
            scanned += events.count
            for event in events {
                guard let courseID = event["course"]["id"].int, session.scope.contains(courseID) else { continue }
                let row = Self.event(event, courseID: courseID, courseName: names[courseID] ?? nil)
                if let eventID, event["id"].int == eventID {
                    return Rows.one(
                        row, characterOffset: window.characterOffset, maxCharacters: window.maxCharacters,
                        notices: arguments.notices)
                }
                matched.append(row)
            }
            guard events.count == ToolCatalog.eventsPerRequest, let last = answer["lastid"].int ?? events.last?["id"].int
            else {
                exhausted = true
                break
            }
            after = last
        }

        if let eventID {
            let reason =
                exhausted
                ? "no event \(eventID) of an allowed course between those dates. Call events_list with the dates it was listed under."
                : "event \(eventID) was not among the first \(scanned) events between those dates. Narrow by from_date and to_date."
            throw .badArgument(name: "eventid", reason: reason)
        }
        let rest = Array(matched.dropFirst(page.offset))
        let extent: Extent =
            exhausted ? .total(matched.count) : rest.count > page.limit ? .moreAfter : .stopped
        let readOne = "events_list, passing its eventid and the same from_date and to_date"
        return Rows.page(
            Array(rest.prefix(page.limit)), offset: page.offset, limit: page.limit, extent: extent, things: "events",
            notices: notices, readOne: ["description": readOne, "description_html": readOne]
        ) { rows in
            .object(["from_date": .date(from), "to_date": .date(toDate), "events": .array(rows)])
        }
    }

    private static func event(_ event: JSON, courseID: Int, courseName: String?) -> Out {
        var row: [String: Out] = [
            "id": .int(event["id"]), "name": .str(event["name"]), "courseid": .int(courseID),
            "course": courseName.map(Out.string) ?? .null,
            "module": .str(event["modulename"]), "instance": .int(event["instance"]),
            "event_type": .str(event["eventtype"]), "date": .date(event["timesort"]),
            "start": .date(event["timestart"]), "overdue": .bool(event["overdue"]), "url": .url(event["url"]),
            "action": event["action"].isNull ? .null : .object([
                "name": .str(event["action"]["name"]), "actionable": .bool(event["action"]["actionable"]),
            ]),
        ]
        Out.html(event["description"], into: &row, key: "description")
        return .object(row)
    }
}
