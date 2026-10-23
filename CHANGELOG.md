# Changelog

## [0.2.4]

- Fixes a crash at launch in 0.2.3: placing the bubble moved the done card before it existed.

## [0.2.3]

- **`answerPermissions` no longer stalls auto mode.** With the option on, Glaude held every call that asked for permission until you clicked Allow, which also kept the auto-mode classifier from deciding: the terminal showed no prompt and the call waited. Glaude now only holds calls in modes where the terminal would ask you (default and accept edits). In auto mode, and in any mode it can't identify, it shows a notice and never blocks. It follows the mode a session starts in and each shift+tab switch.
- The peek card follows the bubble when you drag it.

## [0.2.2]

- **Replies work after `/resume`.** Resuming another conversation inside a running session stopped that session from taking replies from Glaude ("Install the glaude plugin to reply from here"), though everything else kept working. Now only leaving the session stops them.
- If a single reply check fails, the session keeps checking instead of giving up on replies.

## [0.2.1]

- **Bubble clicks always register.** A click that moves the pointer by a few points (common on trackpads) used to count as a tiny drag and was lost. Now anything under 4 pt of movement is a click.
- With "Only When Claude Needs You", the edge tab now sits inside the bubble's own space, so the bubble no longer flickers in and out when the pointer is at the very edge of the screen.

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
