# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule — read-only, always

This server reads one Moodle site and **never writes to it**. Work done with outside help
can be graded as zero, so nothing reachable from this code may start, open,
review or save a quiz attempt, see quiz questions or answers, submit or upload, post to a
forum, send a message, mark anything as read, record a view (`*_view_*` logs the visit and
can tick an activity complete) or change completion or the user profile.

- `WebServiceFunction` is the allow-list; `MoodleClient` takes only its cases.
  `ForbiddenFunctions` is a second, independent deny check run on the exact name about to
  be sent. Adding a function means checking Moodle's documentation for side effects first
  and keeping `FunctionAllowListTests` green. There is no generic call tool and there must
  never be one.
- `CourseScope` is the course allow-list from `config.json`. Every tool that takes a
  course id validates it; every answer that can mention other courses is filtered. Other
  courses are never shown, not even their names.
- The only place any tool writes is `~/Downloads/moodle-mcp/<course short name>/`
  (`file_download`). It never overwrites, never writes under `~/Documents`, and only
  fetches `pluginfile.php` URLs of this site whose context is a module of the given
  course. Archiving a downloaded file elsewhere is the owner's separate step.

**Side effects were checked in the source, not assumed.** Every allow-listed function's
body in `MOODLE_405_STABLE` (and the API it delegates to: `core_message\api`,
`message_popup\api`, `core_calendar\local\api`) was searched for `->trigger(`,
`mark_*`, `*_viewed`, completion updates and `insert/update/delete_record`: none.
`get_course_contents` only reads completion state. Re-check when Moodle is upgraded past
4.5 or a function is added.

**Tests run against fakes** — `FakeTransport`, `FakeTokenStore` and the synthetic fixtures
under `Tests/MoodleMCPCoreTests/Fixtures`, whose names, ids and tokens are invented. Never
the real site, never the real Keychain item. Fixtures recorded from the real site must
have every personal value replaced and every token removed before they are committed.

**Talking to the real site is the owner's call, not yours.** Ask in chat as an explicit
choice, saying exactly what will run and which functions it calls. Only read functions
exist, but every call uses the owner's token and is logged by the site's server.

## The token

A generic password in the login keychain, service `com.eneko.moodle-mcp`, account from
`config.json` (which also holds the site URL: there is no default site in the code). It must be readable **with nobody at the keyboard**, so:

- `KeychainTokenStore.readToken` forbids dialogs (`kSecUseAuthenticationUIFail` and
  `SecKeychainSetUserInteractionAllowed(false)`, both deprecated, both still what the
  file-based keychain consults). A read the access list does not allow fails with
  `TOKEN_NEEDS_TRUST` instead of hanging.
- `writeToken` deletes and re-adds the item, so the program that writes it becomes its
  trusted application. `login` and `import-token` therefore live in this same binary.
- The binary must be signed with a real identity (`scripts/pack.sh` refuses ad hoc). The
  access list keys on the designated requirement (`identifier "codes.eneko.moodle-mcp"` +
  certificate leaf), which survives rebuilds; an ad-hoc cdhash would not.
- The token goes in the POST body, never a URL. It never reaches stdout, logs, errors or
  answers: models do not decode it, `Redaction` drops `token`/`userprivateaccesskey` keys
  at every depth and scrubs `token=` parameters and the literal token from every outgoing
  text.

The binary is signed with a personal certificate whose subject names its holder: never
publish the binary or the `.mcpb`.

## What this is

A local MCP server (Swift 6, stdio transport) for Moodle's REST web-service API
(`POST /webservice/rest/server.php?moodlewsrestformat=json`, form-encoded, lists as
`name[0]=…`). The token comes from `login/token.php` with `service=moodle_mobile_app`.

## APIs

- [Moodle web services](https://moodledev.io/docs/apis/subsystems/external); the function
  list is in `WebServiceFunction`. `login/token.php` has no page of its own in Moodle's
  developer documentation; its shape (`token`/`privatetoken`, or `error`/`errorcode`) is
  handled in `MoodleClient.requestToken`.
- [URLSession](https://developer.apple.com/documentation/foundation/urlsession), ephemeral,
  30 s per request, one request at a time and at least 500 ms between starts.
- [Keychain Services](https://developer.apple.com/documentation/security/keychain-services):
  `SecItemCopyMatching`, `SecItemAdd`, `SecItemDelete`,
  `SecKeychainSetUserInteractionAllowed`.
- `readpassphrase(3)` for the password prompt.

## Tools

`moodle_status`, `courses_list`, `course_contents`, `file_download`, `assignments_list`,
`quizzes_list`, `events_list`, `notifications_list`, `forums_list`, `forum_discussions`,
`discussion_posts`, `conversations_list`, `conversation_get`, `grades_get`,
`profile_get`. One tool per thing the site holds, named like the owner's other servers
(English snake_case, `_list` / `_get`). Answers are JSON built field by field from `Out`;
nothing Moodle sends reaches an answer unless a tool names it.

Course filtering where Moodle's answer does not say the course:
- `forum_discussions`: the forum must be one `mod_forum_get_forums_by_courses` lists for
  an allowed course, checked before asking.
- `discussion_posts`: Moodle's answer carries `courseid`; outside the list, refused.
- `conversations_list` / `conversation_get`: group conversations (type 2) are kept only
  when `subname` is an allowed course's full name; individual and self conversations
  belong to no course and are kept. `conversation_get` only opens an id the list shows.
- `notifications_list`: attributed by `customdata` (`courseid`, `cmid`) or the context
  URL (`course/view.php?id=`, `course=`/`courseid=`, a module page of an allowed course);
  anything else is hidden and only counted.

## Surface not used

- Every Moodle write function, view logger and mark-as-read (see the data rule).
- `admin/tool/mobile/launch.php`: not used: it opens a browser flow, and
  some sites' proxies block it. `login/token.php` is the route to a token.
- `privatetoken` from `login/token.php`: dropped, never stored.
- `core_message_get_conversation` (single conversation), `core_course_get_categories`
  and every other read not in `WebServiceFunction`: not needed, so not allowed.
- `NSAttributedString` HTML import for `HTMLText`: it runs WebKit and may fetch remote
  resources named in the markup.
- The data-protection keychain and `LAContext`: the item lives in the file-based login
  keychain, which they do not govern.

## Commands

```bash
swift build
swift test
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
extension/server/moodle-mcp selftest      # live: calls site_info and the courses list
```

`login`, `import-token` and `selftest --discover` are interactive and run by the owner.

## Diagnostics

Logs go to stderr through `Diagnostics` (Claude Desktop writes them to
`~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream in server
mode: never `print` there. Log a fixed event, a tool or function name, the error's kind,
the attempt number and a duration — never an argument, a result, Moodle's message text or
the token.
