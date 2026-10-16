# Glaude 🌀

A tiny, open-source desktop companion for Claude Code. Get notified when Claude needs you, without staying glued to your terminal.

<!-- docs/glaude.gif: a short recording of the bubble, a done card and a reply -->

Glaude is a small bubble that floats at the edge of your screen while you work in other apps:

- **It shows what Claude is doing.** A spinning ring while a session works, an orange pulse when it needs you, and a green check when it's done. A badge counts your open sessions.
- **It tells you when a session finishes.** A card next to the bubble shows Claude's last message and how many files and commands the turn touched.
- **You can reply from it.** Click the bubble to open a small chat panel for each session. Type a follow-up there and it runs as a normal prompt in that session.
- **It answers Claude's questions.** When Claude asks you a multiple-choice question, you can answer it in the panel.
- **It flags what only the terminal can answer.** A plan waiting for approval shows as a pinned card with an **Open terminal** button. So does a permission prompt that's still waiting after a few seconds; the wait means calls the auto-mode classifier approves on its own don't set off a card.

## Requirements

- macOS 14 or later, on Apple silicon
- Claude Code 2.1.301 or later, in a terminal (Glaude is a Claude Code [mod](https://code.claude.com/docs/en/plugins/mods/overview))
- To build from source: the Xcode Command Line Tools (`xcode-select --install`)

## Install

Glaude has two parts: the app, and a plugin that connects each Claude Code session to it.

**1. The app.** Build it from source:

```bash
git clone https://github.com/vaseemcholakkan123/Glaude.git
cd Glaude
./app/build.sh
open app/build/Glaude.app
```

Or download `Glaude-<version>-macos-arm64.zip` from [Releases](https://github.com/vaseemcholakkan123/Glaude/releases) and unzip it. The app is signed ad hoc, not notarized, so macOS blocks it the first time. Clear the block with:

```bash
xattr -dr com.apple.quarantine Glaude.app
```

The bubble appears at the right edge of the screen, and a sparkle in the menu bar holds the settings.

**2. The plugin.** At a Claude Code prompt:

```
/plugin install glaude --marketplace vaseemcholakkan123/Glaude
```

Answer `y` to add the marketplace, then pick a scope (the user scope covers every project). From a shell instead:

```bash
claude plugin install glaude --marketplace vaseemcholakkan123/Glaude
```

The plugin is active right away, and in every session you start afterwards. Glaude's menu has **Copy Plugin Install Command** if you need the line again.

## Options

| Option | Default | What it does |
|---|---|---|
| `answerPermissions` | off | Adds **Allow** and **Deny** buttons to Glaude's permission cards. Claude waits up to 2 minutes for your answer there, then shows the terminal prompt. |

Leave `answerPermissions` off if you use auto mode. A plugin can't tell which permission mode a session is in, so with this option on, Glaude would also hold calls that the auto-mode classifier would otherwise decide by itself. Change the option with `/plugin configure glaude@glaude`.

## How it works

```
 Claude Code session                         Glaude.app
┌──────────────────────────┐   localhost   ┌─────────────────────────┐
│ glaude mod               │ ────────────▶ │ server on 127.0.0.1     │
│  · session, prompt, tool │   events      │  · bubble, cards, panel │
│    and turn events       │ ◀──────────── │                         │
│  · submits your replies  │   replies,    │                         │
│  · answers questions     │   answers     │                         │
└──────────────────────────┘               └─────────────────────────┘
```

- The mod reaches the app at `127.0.0.1` only, with a random token the app keeps in `~/.glaude`. Nothing leaves your Mac.
- If the app isn't running, the mod does nothing and Claude Code behaves exactly as without it. Every hook falls through to Claude Code's own behaviour when Glaude can't be reached.
- A reply typed in Glaude reaches the session as a prompt from the plugin, once the session is idle.

### What the plugin can access

`claude plugin validate mod` lists it:

- **Events:** `session.start`, `session.end`, `prompt.submit`, `tool.call`, `tool.check`, `turn.complete`, and `ui.render` for the terminal's run-in-background pill. It draws nothing; the pill tells it a call is running, so a permission card can go.
- **Calls:**
  - `$.http.fetch`, to `127.0.0.1` only
  - `$.fs.read`, for `~/.glaude/port` and `~/.glaude/token`
  - `$.env.get('HOME')`
  - `$.process.run(['/bin/sh', '-c', 'echo $PPID'])`, once per session, for the process id that **Open terminal** uses
  - `$.prompt.submit`, for your replies
  - `$.session.id`
  - `$.clock.after`

## Troubleshooting

- **Is the plugin loaded?** Run `/plugin` in a session. The dim line under the tabs should read `1 mod active · glaude` (or include `glaude`).
- **Is the app receiving anything?** Ask it directly:
  ```bash
  curl -H "X-Glaude-Token: $(cat ~/.glaude/token)" "127.0.0.1:$(cat ~/.glaude/port)/state"
  ```
- **Nothing happens at work.** Your organization can turn off plugins you install yourself, for example with `allowManagedModsOnly`, `allowManagedHooksOnly`, `disableAllHooks` or a marketplace allowlist. Mods are on by default, so if they're off for you, an admin turned them off. See [Manage mods for your organization](https://code.claude.com/docs/en/plugins/mods/admin).
- **The reply box doesn't appear.** It appears once the session's plugin is polling Glaude, a moment after the session starts. Sessions started before you installed the plugin need a restart, or `/reload-plugins`.

## Uninstall

1. In Claude Code, run `/plugin uninstall glaude@glaude`.
2. Quit Glaude from its menu, then delete `Glaude.app` and `~/.glaude`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Glaude is an independent project and is not affiliated with or endorsed by Anthropic.
