# Glaude 🌀

A tiny, open-source desktop companion for Claude Code. Get notified when Claude needs you, without staying glued to your terminal.

<!-- docs/glaude.gif: a short recording of the bubble, a done card and a reply -->

Glaude is a small bubble that floats at the edge of your screen while you work in other apps:

- **It shows what Claude is doing.** A spinning ring while a session works, an orange pulse when it needs you, and a green check when it's done. A badge counts your open sessions.
- **It tells you when a session finishes.** A card next to the bubble shows Claude's last message and how many files and commands the turn touched.
- **You can reply from it.** Click the bubble to open a small chat panel for each session. Type a follow-up there and it runs as a normal prompt in that session.
- **It answers Claude's questions.** When Claude asks you a multiple-choice question, you can answer it in the panel.
- **It flags what only the terminal can answer.** A plan waiting for approval shows as a pinned card with an **Open terminal** button. So does a permission prompt that's still waiting after a few seconds; the wait means calls the auto-mode classifier approves on its own don't set off a card.
- **It shows what changed.** Edit and Write steps show `+N −M`; click one for the diff.
- **It shows your plan usage.** The 5-hour and weekly limits sit in the panel header, and each session shows how full its context window is.
- **It stays out of the way, if you like.** Choose **Bubble: Only When Claude Needs You** and it tucks into a slim tab in the screen edge until a session is blocked on you.
- **It takes you to the right tab.** Open terminal brings up the session's own tab in Ghostty, iTerm2 or Terminal.

## Requirements

- macOS 14 or later, on Apple silicon
- Claude Code 2.1.301 or later, in a terminal (Glaude is a Claude Code [mod](https://code.claude.com/docs/en/plugins/mods/overview))
- Only to build from source: the Xcode Command Line Tools (`xcode-select --install`) or Xcode

## Install

Glaude has two parts: the app, and a plugin that connects each Claude Code session to it.

**1. The app.** Download `Glaude-<version>-macos-arm64.zip` from [Releases](https://github.com/vaseemcholakkan123/Glaude/releases) and unzip it into Applications. The app is signed ad hoc, not notarized, so macOS blocks it the first time. Clear the block, then open it:

```bash
xattr -dr com.apple.quarantine /Applications/Glaude.app
open /Applications/Glaude.app
```

Or build it from source (this needs the Xcode Command Line Tools; if the build reports a missing macro plugin, install Xcode or use the release):

```bash
git clone https://github.com/vaseemcholakkan123/Glaude.git
cd Glaude
./app/build.sh && open app/build/Glaude.app
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

## Shortcuts and settings

| Shortcut | Does |
|---|---|
| ⌃⌥G | Open or close the panel |
| ⌃⌥J | Jump to the session that needs you (or the latest one): its terminal tab and the panel |

Settings live in the menu under the ✦ icon in the menu bar. The same menu opens from a right-click on the bubble, or the ⋯ button in the panel. There you can pick **Bubble: Always Visible** or **Only When Claude Needs You**, and turn sounds, notifications and Launch at Login on or off.

**Notifications** need Glaude in an Applications folder (macOS refuses them otherwise) and your permission the first time. If you build from source, `./app/build.sh --install` copies the app to `~/Applications`. **Open terminal** asks once per terminal app for permission to control it (System Settings → Privacy & Security → Automation).

## Options

| Option | Default | What it does |
|---|---|---|
| `answerPermissions` | off | Adds **Allow** and **Deny** buttons to Glaude's permission cards. Claude waits up to 2 minutes for your answer there, then shows the terminal prompt. |
| `notifications` | `glaude` | Who sends notifications: `glaude` (Glaude's own, with buttons), `claude` (Claude Code's channel from `/config`, finished turns only, no buttons) or `off`. |

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
  - `$.env.get('HOME')` and `$.env.get('PWD')` (the folder Claude was started in, to find its Ghostty tab)
  - `$.process.run(['/bin/sh', '-c', 'echo $PPID; ps -o tty= -p $PPID'])`, once per session, for the process id and terminal that **Open terminal** uses
  - `$.session.usage`, for the plan limits and context fill
  - `$.ui.notify`, only with `notifications: claude`
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

## Updating

Update both parts when a new version comes out; [Releases](https://github.com/vaseemcholakkan123/Glaude/releases) and [CHANGELOG.md](CHANGELOG.md) list what changed.

**The plugin.** From your shell:

```bash
claude plugin update glaude@glaude
```

Or in a session: `/plugin` → **Installed** → **glaude** → **Update now**. Then run `/reload-plugins` in sessions that are already open (new sessions pick it up by themselves).

To get plugin updates automatically: `/plugin` → **Marketplaces** → **glaude** → **Enable auto-update**. Third-party marketplaces have it off by default.

**The app.** Quit Glaude first (✦ menu → **Quit Glaude**), then:

- **From a release:** download the new zip, replace `Glaude.app` in Applications with the one inside, and run
  ```bash
  xattr -dr com.apple.quarantine /Applications/Glaude.app && open /Applications/Glaude.app
  ```
- **From source:**
  ```bash
  cd Glaude && git pull && ./app/build.sh --install && open ~/Applications/Glaude.app
  ```

Your settings (bubble position, sounds, notifications) carry over. macOS may ask again for permission to control your terminal, because each build has a new ad-hoc signature.

## Uninstall

1. In Claude Code, run `/plugin uninstall glaude@glaude`.
2. Quit Glaude from its menu, then delete `Glaude.app` and `~/.glaude`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Glaude is an independent project and is not affiliated with or endorsed by Anthropic.
