<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="moodle-mcp icon">
</p>

# moodle-mcp

A local MCP server, written in Swift, that gives Claude **read-only** access to one Moodle
site through Moodle's web-service API. It reads your courses' contents, assignments,
quizzes, calendar deadlines, forums, notifications, messages and grades, but only for the
courses you confirm. It ships as a Claude extension. The token lives in your login keychain
and is never shown to Claude.

**It cannot change anything on the site.** It cannot:
- start, open or review a quiz attempt, or see quiz questions or answers;
- submit or upload anything;
- post to a forum or send a message;
- mark anything as read;
- record a view or a completion.

Not affiliated with, endorsed by, or connected to Moodle Pty Ltd.

## What you can ask

- "What is due in the next two weeks?"
- "Have I submitted the first assignment of every course?"
- "Summarise the new posts in this course's forums."
- "Download the PDFs of unit 2."
- "What are my grades so far?"

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Tools](#tools)
- [What the answers look like](#what-the-answers-look-like)
- [Messages and internal mail](#messages-and-internal-mail)
- [Safety rules](#safety-rules)
- [Privacy: what is stored and what is sent](#privacy-what-is-stored-and-what-is-sent)
- [Troubleshooting](#troubleshooting)
- [Known limits](#known-limits)
- [Frameworks and APIs](#frameworks-and-apis)
- [Development](#development)
- [Licence](#licence)

## Requirements

- macOS 15 or later on Apple silicon.
- Xcode or the Swift 6 toolchain, to build it.
- An Apple Development or Developer ID signing identity. An ad-hoc signature will not do;
  see [Signing](#signing-and-why-it-is-not-optional).
- A Moodle site that has web services and the mobile app service (`moodle_mobile_app`)
  turned on, and your account on it. If the official Moodle app can log in to your site,
  this server can too.

## Install

### 1. Build the bundle

```bash
security find-identity -v -p codesigning     # copy the hash of an Apple Development or Developer ID Application identity
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
```

The script:
1. builds the release binary and checks that it is arm64;
2. signs it with that identity;
3. prints its designated requirement, with the certificate's name replaced by `<identity>`;
4. writes `dist/moodle-mcp.mcpb`.

### 2. Install it in Claude

Open `dist/moodle-mcp.mcpb` with Claude and confirm the install. Then **quit Claude
completely and reopen it**. Installing does not replace a server that is already running.

### 3. Log in and choose your courses

Run these in Terminal, with the binary Claude installed:

```bash
BIN="$HOME/Library/Application Support/Claude/Claude Extensions/local.mcpb.eneko-codes.moodle-mcp/server/moodle-mcp"
"$BIN" login                                 # site (first time only), username, password (not shown)
"$BIN" selftest --discover --category <id>   # lists your courses in that category; confirm to save them
"$BIN" selftest                              # checks the token works with no Keychain dialog
```

- **What login does with your password:** it sends it once, only to the site's
  `login/token.php`, and never stores it. That request is never retried, so a network
  failure means running `login` again.
- **What is saved:** the site address, your username, the course ids and the category, in
  `~/Library/Application Support/moodle-mcp/config.json` (mode `0600`).
- **The category id** is the number in the address of the category page
  (`course/index.php?categoryid=<id>`). Leave out `--category` on later runs: the saved
  one is reused.

Each update is a new version of the extension: open the new `.mcpb` and restart Claude. Your
token, settings and courses are kept.

### Signing, and why it is not optional

The server reads the token with nobody at the keyboard, so it never lets the Keychain show a
dialog. If the Keychain item does not trust the program, the read fails with
`TOKEN_NEEDS_TRUST` rather than waiting for a click.

`login` writes the Keychain item from this binary, which makes the binary the item's trusted
application. `import-token` does the same for a token that was stored by other means. That
trust is tied to the binary's designated requirement: its signing identifier plus its
certificate. An ad-hoc signature has no designated requirement, so every rebuild would lose
the trust. That is why `scripts/pack.sh` refuses to sign ad hoc.

A signing certificate's subject carries its holder's name. **Never publish a binary or a
bundle signed with a personal certificate.**

### Tool switches

Claude Desktop lets you turn each tool on and off, because the bundle lists all of them in
its manifest. `file_download` is the only tool not marked read-only, because it writes a
file to your Mac. **Reinstalling can reset the switches, so check them after every
install.**

### Manual registration instead of the bundle

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

- Sign that binary with a real identity too, and run `login` with that same binary.
- You lose the per-tool switches.
- Do not install the bundle as well: two servers registered under the same name collide.

### Uninstall

1. Remove the extension in Claude's settings.
2. Delete the token:

   ```bash
   security delete-generic-password -s com.eneko.moodle-mcp -a <your username>
   ```

3. Delete the settings folder, `~/Library/Application Support/moodle-mcp`.
4. Optionally, delete the downloads folder, `~/Downloads/moodle-mcp`.

## Tools

| Tool | Kind | Moodle function(s) | What it returns |
|---|---|---|---|
| `moodle_status` | read | `core_webservice_get_site_info` | Whether the token works, the site and Moodle release, your user id and name, the number of allowed courses, and any function this server needs that the site does not grant |
| `courses_list` | read | `core_enrol_get_users_courses` | The allowed courses: id, full name and short name |
| `course_contents` | read | `core_course_get_contents` | Sections and their modules (type, dates, your completion) with their files, as one list of entries; one module (`cmid`) or section (`sectionid`) in full |
| `file_download` | local write | the file's URL, through `webservice/pluginfile.php` | Saves one course file under `~/Downloads/moodle-mcp/<course short name>/` and returns its path, size and SHA-256 |
| `assignments_list` | read | `mod_assign_get_assignments`, `mod_assign_get_submission_status` | Dates, maximum grade, introduction, your submission's status and your grade, soonest due first; one in full by `assignmentid` |
| `quizzes_list` | read | `mod_quiz_get_quizzes_by_courses`, `mod_quiz_get_user_attempts` | Dates, time limit, attempts allowed, your attempts' state and grade, soonest closing first; one quiz with every attempt by `quizid`. Never the questions |
| `events_list` | read | `core_calendar_get_action_events_by_timesort` | Deadlines and other action events between `from_date` and `to_date`; one in full by `eventid` |
| `notifications_list` | read | `message_popup_get_popup_notifications` | Your notifications that can be traced to an allowed course; one in full by `notificationid` |
| `forums_list` | read | `mod_forum_get_forums_by_courses` | Forums, with their number of discussions and unread posts; one in full by `forumid` |
| `forum_discussions` | read | `mod_forum_get_forum_discussions` | A forum's discussions, in Moodle's default order |
| `discussion_posts` | read | `mod_forum_get_discussion_posts` | The posts of one discussion, oldest first, with attachments; one in full by `postid` |
| `conversations_list` | read | `core_message_get_conversations` | Your Moodle message conversations (see [Messages](#messages-and-internal-mail)) |
| `conversation_get` | read | `core_message_get_conversation_messages` | One conversation's messages, newest first; one in full by `messageid` |
| `grades_get` | read | `gradereport_user_get_grade_items` | Your grade items in one course; one in full by `itemid` |
| `profile_get` | read | `core_user_get_users_by_field` | Your custom profile fields and city, nothing else; one field in full by `shortname` |

Claude starts with `moodle_status`, then calls `courses_list` for the course ids the other
tools take. `assignments_list` and `quizzes_list` make one request per activity on the
page, so a page of them takes a few seconds; a call that runs long stops starting new
requests, returns what it has and says it is partial.

## What the answers look like

- **Dates** are in Europe/Madrid time, each given in two forms:
  `{"iso": "2026-11-20T23:59:00+01:00", "fecha_local": "20/11/2026 23:59"}`. A missing
  date is `null`, never 1 January 1970.
- **Text** that Moodle sends as HTML comes as plain text, with links kept as
  `text (url)`. The original HTML is beside it, in a field ending in `_html` (`message` and
  `message_html`, for example).
- **File URLs** never carry the token. Pass one to `file_download` to save the file.
- **Every answer is bounded.** A listing returns one page, in an order it states, and its
  first lines say in plain words, before the JSON, how many there are and the `limit` and
  `offset` of the next page. A long text (a summary, an introduction, a message, feedback)
  is clipped in a listing, as plain text and as HTML; the notice names the id argument that
  reads that one item in full, a window at a time, with `character_offset` and
  `max_characters`. Dates are filtered with `from_date` and `to_date`, both inclusive.
  Rows that belong to another course are never shown, and a page says how many it left
  out. Arguments a tool does not take are refused, so a call that still uses a name from
  before version 1.0 (`from`, `to`, `page`, `perpage`) fails instead of being ignored.

## Messages and internal mail

"Messages" on a Moodle site can mean three different things. This server reads the first
two and cannot reach the third.

| What | Where it shows on the site | Read here? |
|---|---|---|
| Notifications | The bell icon: new forum posts, grading, deadlines | Yes, with `notifications_list`, for the allowed courses |
| Moodle messaging | The speech-bubble icon, and the Messages drawer | Yes, with `conversations_list` and `conversation_get`, if the site has it turned on |
| An internal mail plugin, such as `local_mail` | A "Mail" or "Correo" page with an inbox, sent items and labels | **No** |

**Moodle messaging can be switched off.** It is a site setting. On a site where it is off,
the conversation tools answer `MESSAGING_DISABLED`: there is nothing to read, and nothing
is broken.

**Internal mail plugins are out of reach of the token.** Some sites replace or supplement
Moodle messaging with a mail plugin; `local_mail` is the common one.
- **Why not:** the token comes from the site's mobile app service (`moodle_mobile_app`), so
  it can call only the functions in that service. Current versions of `local_mail` declare
  their web-service functions for the site's own pages, not for that service. The Moodle
  app shows the mail by opening the web page itself.
- **How it was checked:** on a site with `local_mail` installed, the token could call 455
  functions, and none of them was `local_mail_*`.
- **Can it change?** Only if the site's administrators add the mail functions to the
  mobile service; nothing on your side can.
- **Why not read the web pages instead?** That would need your password on every run rather
  than a token, would break whenever the site's theme changed, and opening a message there
  marks it as read.

Reading never marks anything as read. That holds for notifications, forum posts and
conversations alike: the functions used here do not mark, and every mark-as-read function
is refused.

## Safety rules

- **A closed list of functions.** The server can call only the sixteen functions named in
  the [Tools](#tools) table.
- **An independent second check.** Before any request is built, it refuses:
  - every quiz-attempt function;
  - every submission, upload, send, post, mark-as-read and user update;
  - every `*_view_*` function, which logs a visit and can tick an activity as completed;
  - generic write verbs, and the function that calls other functions by name.
- **No generic tool.** No tool can call a function by name.
- **Side effects checked in Moodle's source.** Each allowed function, and the code it calls,
  was read in Moodle 4.5 looking for events, mark-as-read, completion updates and database
  writes. None has any.
- **Only the courses you confirm.**
  - Every course id is checked against your list.
  - Answers that can mention other courses are filtered first: calendar, notifications,
    forums and group conversations.
  - Other courses are never shown, not even their names.
- **One local write, and only one.** `file_download` saves to
  `~/Downloads/moodle-mcp/<course short name>/` and nowhere else. It never overwrites: an
  identical file is reported as already there, and a different one gets a numbered name.
  It fetches only `<site>/pluginfile.php/<context>/…` or
  `<site>/webservice/pluginfile.php/<context>/…` URLs that:
  - use https, on the site's own host and port;
  - have a context that belongs to a module of the course named;
  - contain no `..` or encoded separators.

  Any query string or fragment the caller added is dropped.
- **The token stays out of sight.**
  - Web-service calls carry it in the request body. File downloads must carry it as a
    `token` parameter, so it goes in the URL of that one request to the site's own
    `webservice/pluginfile.php`, and nowhere else.
  - The file URLs handed to Claude never contain it.
  - No answer, error or log line contains it.
  - `userprivateaccesskey` is removed from every answer.
- **No detours.** A redirect is followed only if it stays on the site's own https host and
  port. Any other is refused, so the token and the password cannot be resent elsewhere.
- **Polite to the site.** One request at a time, at most about two a second, with a 30 s
  timeout. A request other than the login is retried once, after 2 s, if the network
  fails, the site answers HTTP 502, 503 or 504, or Moodle says `servicenotavailable`.

## Privacy: what is stored and what is sent

| What | Where |
|---|---|
| The token | Your login keychain, service `com.eneko.moodle-mcp` |
| Site address, username, course ids, category | `~/Library/Application Support/moodle-mcp/config.json`, mode `0600` |
| Downloaded files | `~/Downloads/moodle-mcp/<course>/` |
| Logs: tool and function names, error kinds, attempts and durations; never content | `~/Library/Logs/Claude/mcp-server-Moodle.log` |

- **The server talks only to your Moodle site.** It makes no other connection.
- **Claude sees the answers.** Whatever a tool returns becomes part of your conversation
  with Claude: course content, forum posts written by other people, your grades. The
  token never does.

## Troubleshooting

| Answer | Meaning | Fix |
|---|---|---|
| `TOKEN_INVALIDO` | Moodle refused the token: it expired, was revoked, or its service lacks a function | Run `"$BIN" login`. If it keeps happening, `moodle_status` lists any function the site does not grant |
| `TOKEN_MISSING` | No token is stored yet | Run `"$BIN" login` |
| `TOKEN_NEEDS_TRUST` | The Keychain item does not trust this binary, often after building with another identity | Run `"$BIN" import-token` once; macOS asks for your login password to let it read the item |
| `NO_ALLOWED_COURSES` | No courses have been confirmed | Run `"$BIN" selftest --discover --category <id>` |
| `COURSE_NOT_ALLOWED` | The course id is not in your list | Use an id from `courses_list`, or add the course with `selftest --discover` |
| `MESSAGING_DISABLED` | The site has Moodle messaging turned off | Nothing to fix; see [Messages](#messages-and-internal-mail) |
| `UNKNOWN_ARGUMENT` | The call passed an argument the tool does not take, often a name from before version 1.0 | The error lists the names the tool takes |
| `TIMED_OUT` | The site did not answer in time, and the call was abandoned | Ask for less (one course, a smaller `limit`), or check the site with `moodle_status` |
| A fix seems not to work | Claude is still running the old server | Quit Claude completely and reopen it; `moodle_status` shows `server_version` |

## Known limits

- **The token is not read-only in itself.** It is a mobile-app token with your own
  permissions on the site, submissions included. This server is what keeps it read-only.
  Another program that got hold of the token could write with it. That includes any program
  signed with your certificate and the same signing identifier, which the Keychain trusts as
  it trusts this server. If you suspect the token has leaked, log out the mobile app
  sessions on the site, if it offers that in your profile, and run `login` again.
- **Moodle records that you connected.** Any web-service call usually updates your
  account's "last access" time. Nothing here marks anything as viewed, read or completed.
- **Internal mail plugins cannot be read.** See [Messages](#messages-and-internal-mail).
- **Times are always Europe/Madrid**, whatever your Mac's time zone.
- **Checked against Moodle 4.5.** The functions and their side effects were checked in the
  `MOODLE_405_STABLE` source. Check them again after the site upgrades.

## Frameworks and APIs

Apple frameworks only: there is **no third-party dependency**, and `Package.swift` lists
none.

| Used | For | Reference |
|---|---|---|
| Moodle web services: `POST /webservice/rest/server.php?moodlewsrestformat=json`, form-encoded | Every read tool | [Moodle external API](https://moodledev.io/docs/apis/subsystems/external) |
| `login/token.php` with `service=moodle_mobile_app` | `moodle-mcp login` | No page of its own in Moodle's developer documentation |
| `URLSession`, ephemeral, with a redirect delegate | HTTPS | [URLSession](https://developer.apple.com/documentation/foundation/urlsession) |
| `SecItemCopyMatching`, `SecItemAdd`, `SecItemDelete`, `SecKeychainSetUserInteractionAllowed` | The token in the login keychain, read with dialogs forbidden | [Keychain Services](https://developer.apple.com/documentation/security/keychain-services) |
| `CryptoKit` `SHA256` | The hash `file_download` reports | [CryptoKit](https://developer.apple.com/documentation/cryptokit) |
| `MCPServer.swift`, `Value.swift` and `ToolStandard.swift`, over Foundation | The stdio server (JSON-RPC over stdio) and the bounds every answer keeps | [Model Context Protocol](https://modelcontextprotocol.io) |

## Development

```bash
swift build
swift test      # fakes only: no network, no Keychain
```

The tests run against an in-memory transport and token store, with invented courses,
people and tokens. `selftest` is the live check: it calls the real site with your real
token, so run it only when you mean to.

## Licence

MIT. Moodle is a registered trademark of Moodle Pty Ltd; the icon is the Moodle app's own,
used to identify the site this server reads.
