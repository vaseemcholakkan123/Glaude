# Changelog

## [0.2.0]

- **Edit diffs:** Edit and Write steps show `+N −M`; click one to see the diff. Done cards and summaries show the turn's totals.
- **Plan usage and context:** the panel header shows your 5-hour and weekly limits, and each session shows how full its context window is.
- **Keyboard shortcuts:** ⌃⌥G opens or closes the panel; ⌃⌥J jumps to the session that needs you.
- **Notifications you can act on:** while the panel is closed, finished turns and requests arrive as macOS notifications with **Reply**, answer buttons and (with `answerPermissions`) **Allow/Deny**. They go away once answered. A new plugin option, `notifications`, picks `glaude` (default), `claude` (Claude Code's own channel from `/config`) or `off`.
- **The exact terminal tab:** Open terminal and ⌃⌥J bring the session's own tab forward in Ghostty, iTerm2 and Terminal.
- **Only when Claude needs you:** an optional mode that tucks the bubble into a slim tab in the screen edge until a session is blocked on you; it glows green when one finishes.
- The settings menu also opens from a right-click on the bubble and the panel's ⋯ button.

## [0.1.1]

- Builds with Swift toolchains whose SDK makes SwiftUI's `@State` a macro: the app no longer uses the `@State` and `@FocusState` macros, which need a compiler plugin the Command Line Tools don't ship.
- `app/build.sh` explains what to do when the build fails, and the README offers the prebuilt release first.

## [0.1.0]

First public release.

- A floating bubble showing whether your Claude Code sessions are working, done or waiting on you, with a count of open sessions.
- A done card with Claude's last message and the files and commands the turn touched.
- A chat panel per session. Replies typed there run as prompts in that session.
- Claude's multiple-choice questions can be answered from the panel.
- Plan approvals and permission prompts show as pinned cards with **Open terminal**. Allow/Deny from the panel is opt-in (`answerPermissions`).
- A resizable panel, sounds, and Launch at Login.
- Connects through the `glaude` Claude Code mod, installed with `/plugin install glaude --marketplace vaseemcholakkan123/Glaude`.
