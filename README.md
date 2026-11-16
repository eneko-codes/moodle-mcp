<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="moodle-mcp icon">
</p>

# moodle-mcp

A local MCP server, written in Swift, that gives Claude **read-only** access to one Moodle
site through Moodle's REST web-service API: your courses' contents, assignments, quizzes,
calendar deadlines, forums, messages, notifications and grades. It is limited to an
allow-list of courses you confirm. The token lives in the login keychain and never leaves
your Mac. It ships as a Claude extension.

It cannot start, open or review a quiz attempt, see quiz questions or answers, submit or
upload anything, post to a forum, send a message, mark anything as read, or record a view or
a completion.

Not affiliated with, endorsed by, or connected to Moodle Pty Ltd.

## Requirements

- macOS 15 or later on Apple silicon
- Xcode or the Swift 6 toolchain, to build from source
- An Apple Development (or Developer ID) signing identity — see [Signing](#signing-and-why-it-is-not-optional)
- A Moodle site with web services and the mobile service (`moodle_mobile_app`) enabled, and
  an account on it

## Tools

| Tool | Kind | Moodle function(s) | What it returns |
|---|---|---|---|
| `moodle_status` | read | `core_webservice_get_site_info` | Whether the token works, Moodle release, your user id, any needed function the site does not grant |
| `courses_list` | read | `core_enrol_get_users_courses` | The allowed courses: id, full and short name |
| `course_contents` | read | `core_course_get_contents` | Sections, modules (type, dates, your completion) and their files |
| `file_download` | local write | the file URL, via `webservice/pluginfile.php` | Saves one course file under `~/Downloads/moodle-mcp/<course>/`; path, size, SHA-256 |
| `assignments_list` | read | `mod_assign_get_assignments`, `mod_assign_get_submission_status` | Dates, maximum grade, introduction, your submission's status, your grade |
| `quizzes_list` | read | `mod_quiz_get_quizzes_by_courses`, `mod_quiz_get_user_attempts` | Dates, time limit, attempts allowed, your attempts' state and grade — never questions |
| `events_list` | read | `core_calendar_get_action_events_by_timesort` | Action events (deadlines) between two dates, at most 200 per call |
| `notifications_list` | read | `message_popup_get_popup_notifications` | Your notifications attributable to an allowed course |
| `forums_list` | read | `mod_forum_get_forums_by_courses` | Forums with discussion and unread counts |
| `forum_discussions` | read | `mod_forum_get_forum_discussions` | One page of a forum's discussions |
| `discussion_posts` | read | `mod_forum_get_discussion_posts` | Every post of one discussion, with attachments |
| `conversations_list` | read | `core_message_get_conversations` | Your message conversations |
| `conversation_get` | read | `core_message_get_conversation_messages` | One conversation's messages |
| `grades_get` | read | `gradereport_user_get_grade_items` | Your grade items in one course |
| `profile_get` | read | `core_user_get_users_by_field` | Your custom profile fields and city, nothing else |

Start with `moodle_status`, then `courses_list` for the ids the other tools take.

Dates are Europe/Madrid, each as `{"iso": "2026-11-20T23:59:00+01:00", "fecha_local": "20/11/2026 23:59"}`,
or `null` when Moodle has none. HTML comes as plain text with links kept, plus the original
in a field ending in `_html`. File URLs never carry the token.

## Frameworks and APIs

Apple frameworks plus the MCP Swift SDK, which brings its own dependencies (SwiftNIO,
swift-log and others, pinned in `Package.resolved`).

| Used | For | Reference |
|---|---|---|
| Moodle web services: `POST /webservice/rest/server.php?moodlewsrestformat=json`, form-encoded | Every read tool | [Moodle external API](https://moodledev.io/docs/apis/subsystems/external) |
| `login/token.php` with `service=moodle_mobile_app` | `moodle-mcp login` | — |
| `URLSession` (ephemeral, 30 s per request) | HTTPS | [URLSession](https://developer.apple.com/documentation/foundation/urlsession) |
| `SecItemCopyMatching`, `SecItemAdd`, `SecItemDelete` | The token in the login keychain | [Keychain Services](https://developer.apple.com/documentation/security/keychain-services) |
| `CryptoKit` `SHA256` | The hash `file_download` reports | [CryptoKit](https://developer.apple.com/documentation/cryptokit) |
| MCP Swift SDK | stdio server | [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) |

## The rules worth knowing before you use it

- **Closed allow-list of functions.** The client can only call the sixteen functions in the
  table above. A second, independent check refuses, before any request, every quiz-attempt
  function, every submission, upload, send, post and mark-as-read, every `*_view_*` (which
  logs a visit and can tick an activity as completed) and every user update. There is no
  generic "call a function" tool.
- **Side effects checked in Moodle's source.** Each allowed function, and the API it
  delegates to, was read in Moodle 4.5 for events, mark-as-read, completion updates and
  database writes. None has any.
- **Only the courses you confirm.** Every course id is checked against the list in the
  configuration file. Answers that can mention other courses (calendar, notifications, group
  conversations, forums) are filtered first; other courses are never shown, not even their
  names.
- **One local write.** `file_download` saves into `~/Downloads/moodle-mcp/<course>/` and
  nowhere else, never overwrites, and only fetches `<site>/pluginfile.php/<context>/…` URLs
  of this site's own host and port whose context is a module of the course named; `..`,
  encoded separators and any query the caller added are refused or dropped.
- **The token stays put.** It goes in the request body, never a URL. No answer, error or log
  line carries it; `userprivateaccesskey` is dropped from every answer.
- **Polite.** One request at a time, about two a second at most, and one retry after 2 s on
  a network failure, HTTP 502/503/504 or `servicenotavailable`, downloads included.
- **No detours.** A redirect is followed only within the site's own https host and port;
  any other is refused, so the token and the password cannot be resent elsewhere.

## Install

### 1. Build the bundle

```bash
security find-identity -v -p codesigning     # pick an identity's hash
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
```

That builds an arm64 binary, signs it with that identity, prints its designated requirement
and writes `dist/moodle-mcp.mcpb`.

### 2. Install it

Open `dist/moodle-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and reopen
it** — installing does not replace a server process that is already running.

### 3. Log in and choose the courses

Run these with the installed binary, in Terminal:

```bash
BIN="$HOME/Library/Application Support/Claude/Claude Extensions/local.mcpb.eneko-codes.moodle-mcp/server/moodle-mcp"
"$BIN" login                                 # site (first time), username, password without echo
"$BIN" selftest --discover --category <id>   # shows your courses in that category; confirm to save
"$BIN" selftest                              # must pass with no Keychain dialog
```

The password is sent once to `login/token.php` and never stored. The site, the account name
and the course ids go to `~/Library/Application Support/moodle-mcp/config.json` (mode
`0600`).

When a tool answers `TOKEN_INVALIDO`, Moodle refused the token: run `login` again. If it
persists, `moodle_status` lists any function the site withholds from the mobile service.

### Signing, and why it is not optional

The server must read the token with nobody at the keyboard, so it never lets the Keychain
show a dialog: a read the item's access list does not allow fails with `TOKEN_NEEDS_TRUST`.
`login` (and `import-token`, for a token stored by other means) writes the item from this
binary, which makes it the trusted application. That trust is tied to the designated
requirement, and an ad-hoc signature has none — every rebuild would lose it — so
`scripts/pack.sh` refuses to sign ad hoc.

A certificate's subject carries its holder's name. **Do not publish a binary or bundle
signed with a personal certificate.**

## Tool switches

Every tool can be turned on and off individually in Claude Desktop, because the bundle
declares all of them in its manifest. `file_download` is the only one not marked read-only,
since it writes a local file. **Reinstalling may reset the switches.** Check them after
every install.

## Manual registration instead

```bash
swift build -c release
```

```json
{
  "mcpServers": {
    "Moodle": {
      "command": "/FULL/PATH/to/moodle-mcp"
    }
  }
}
```

Sign that binary with a real identity too, and run `login` with it. You lose the per-tool
switches. Do not do both at once: two registrations under the same name collide.

## Known limits

- **The token is not read-only.** It is a mobile-app token with your own permissions on the
  site, submissions included. This server is the cage that makes it read-only; anything else
  that read it from the Keychain could write. If you ever get suspicious, log out of the
  mobile app sessions on the site and run `login` again.
- **Moodle records that you connected.** Any web-service call usually updates your
  account's "last access". Nothing here marks anything viewed, read or completed.
- **Messaging may be off.** On a site with Moodle's messaging disabled the conversation
  tools answer `MESSAGING_DISABLED`, and there is nothing to read.
- **Internal mail plugins are out of reach.** A plugin such as `local_mail` declares its
  functions for the browser only, not for the mobile web service the token belongs to, so
  the token cannot call them. Only the site's administrators could add them to that
  service; reading the mail through the web pages instead would need the password and
  would mark messages as read.
- **Dates are fixed to Europe/Madrid.**
- **Checked against Moodle 4.5.** Functions and their side effects were checked in the
  `MOODLE_405_STABLE` source; re-check after the site upgrades.

## Development

```bash
swift build
swift test      # fakes only: no network, no Keychain
```

The suite runs against an in-memory transport and token store with invented data. `selftest`
is the live check, and it calls the real site with your real token; run it only when you
mean to.

## Licence

MIT.
