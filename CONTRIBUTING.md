# Contributing to Glaude

Issues and pull requests are welcome. For anything bigger than a fix, open an issue first so we can agree on the approach.

## Layout

| Path | What it is |
|---|---|
| `app/Sources/Glaude/` | The macOS app (SwiftUI and AppKit, no dependencies). `Server.swift` is the localhost server, `SessionStore.swift` the session model, and `ChatView.swift`, `BubbleView.swift` and `main.swift` the UI. |
| `app/build.sh` | Builds `app/build/Glaude.app` with `swiftc`. There's no Xcode project. |
| `mod/` | The `glaude` Claude Code mod: `hooks/register.ts`, plus its tests in `tests/`. |
| `.claude-plugin/marketplace.json` | Makes this repository a plugin marketplace that lists `mod/`. |

## Working on the app

```bash
./app/build.sh && open app/build/Glaude.app
```

Quit the running copy first (menu bar sparkle → **Quit Glaude**). Check what the app holds with `GET /state` (see the README).

## Working on the mod

Load your working copy into a session in place of an installed one:

```bash
claude --plugin-dir ./mod
```

Run the checks before you open a pull request:

```bash
claude plugin validate .        # marketplace, manifest and hooks module
claude plugin test mod          # mod/tests/*.test.ts
```

To type-check, load the mod once with `--plugin-dir` (Claude Code then writes its types to `mod/.claude-plugin/types/`), then run `npx tsc -p mod`.

The protocol between the two parts:

| Request | Purpose |
|---|---|
| `POST /event` | A status event. The body has `session_id`, `hook_event_name`, `cwd`, `pid`, and the event's fields. |
| `GET /reply/next?session=` | Long-poll for a reply typed in Glaude: 200 `{text}`, or 204 after 25 s. |
| `POST /wait?request=`, then `GET /wait/next?request=` | A question or permission card: 200 with the answer, 202 still waiting (poll again), 204 no answer. |
| `POST /cancel?request=` | The session stopped waiting. |

Every long-poll answers within 25 s, because a mod's `$.http.fetch` gives up at 30 s. Every request carries `X-Glaude-Token`.

### Checked by hand

The kit's tests can't produce a real tool call's `tool_use_id`, so check the permission path in a live session in default mode:

1. A command or file write that asks for permission shows Glaude's **Allow …?** card, and answering in the terminal clears it.
2. With `answerPermissions` on (`/plugin configure glaude@glaude`), **Allow** and **Deny** in Glaude decide the call.

## Releasing

1. Bump `version` in `mod/.claude-plugin/plugin.json` and `CFBundleShortVersionString` in `app/build.sh`, and add a `CHANGELOG.md` section.
2. Tag `v<version>` and push the tag. The release workflow checks the versions match, builds the app, and attaches the zip to a GitHub release.
