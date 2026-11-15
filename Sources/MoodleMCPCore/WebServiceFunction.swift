import Foundation

/// The only Moodle web-service functions this program can ever call.
///
/// This enum is the allow-list: `MoodleClient` takes a case, never a string, so a function
/// that is not listed here cannot be requested. Strings from outside (a test, a future
/// caller) come in only through `init(validating:)`, which refuses anything not listed.
///
/// Every case only reads. Work done with outside help can be graded as zero, so
/// nothing reachable from here may start, open or touch a quiz attempt, submit or upload,
/// post, send, mark as read, or record a view (a `*_view_*` call logs the visit and can
/// tick an activity as completed). Adding a case means checking it against
/// `ForbiddenFunctions` and against Moodle's own documentation for side effects first.
public enum WebServiceFunction: String, CaseIterable, Sendable {
    case siteInfo = "core_webservice_get_site_info"
    case usersCourses = "core_enrol_get_users_courses"
    case courseContents = "core_course_get_contents"
    case assignments = "mod_assign_get_assignments"
    case submissionStatus = "mod_assign_get_submission_status"
    case quizzes = "mod_quiz_get_quizzes_by_courses"
    case quizUserAttempts = "mod_quiz_get_user_attempts"
    case actionEvents = "core_calendar_get_action_events_by_timesort"
    case forums = "mod_forum_get_forums_by_courses"
    case forumDiscussions = "mod_forum_get_forum_discussions"
    case discussionPosts = "mod_forum_get_discussion_posts"
    case conversations = "core_message_get_conversations"
    case conversationMessages = "core_message_get_conversation_messages"
    case popupNotifications = "message_popup_get_popup_notifications"
    case gradeItems = "gradereport_user_get_grade_items"
    case usersByField = "core_user_get_users_by_field"

    /// The single entry point for a function named by a string. Refuses before any
    /// request exists: a forbidden name first (so the error says why), then anything
    /// merely unlisted.
    public init(validating name: String) throws(MoodleError) {
        if ForbiddenFunctions.matches(name) { throw .functionForbidden(name) }
        guard let function = WebServiceFunction(rawValue: name) else {
            throw .functionNotAllowed(name)
        }
        self = function
    }
}

/// A second, independent check: names that must never be called whatever the allow-list
/// says. `MoodleClient` runs it again on the exact string it is about to send, so a
/// mistaken addition to `WebServiceFunction` is still refused at the wire.
public enum ForbiddenFunctions {

    /// Named outright in the project's rules.
    public static let exact: Set<String> = [
        // Quizzes: an attempt must never be started, opened, reviewed or saved.
        "mod_quiz_start_attempt", "mod_quiz_get_attempt_data", "mod_quiz_get_attempt_review",
        "mod_quiz_get_attempt_summary", "mod_quiz_process_attempt", "mod_quiz_save_attempt",
        // Submissions.
        "mod_assign_save_submission", "mod_assign_submit_for_grading", "core_files_upload",
        // Messages.
        "core_message_send_instant_messages", "core_message_send_messages_to_conversation",
        // Forums.
        "mod_forum_add_discussion", "mod_forum_add_discussion_post",
        // Completion.
        "core_completion_update_activity_completion_status_manually",
    ]

    /// Families refused by shape: any view logger, any mark-as-read, any user update.
    /// Plus the generic write verbs, so a write function nobody thought to list is
    /// refused too.
    static func matchesPattern(_ name: String) -> Bool {
        if name.contains("_view_") || name.hasSuffix("_view") { return true }
        if name.contains("_mark_") && name.contains("_read") { return true }
        if name.hasPrefix("core_user_update_") { return true }
        let writeVerbs = [
            "_save_", "_submit_", "_send_", "_add_", "_delete_", "_update_", "_create_",
            "_upload", "_start_attempt", "_process_attempt", "_get_attempt_",
        ]
        return writeVerbs.contains { name.contains($0) }
    }

    public static func matches(_ name: String) -> Bool {
        exact.contains(name) || matchesPattern(name)
    }
}
