import type { EngineInterface, Register, Timer } from 'claude-code'

// Glaude mod: reports this session to the Glaude desktop app on 127.0.0.1 and submits
// the replies you type there. Every hook passes the event on unchanged unless Glaude
// answered it, and any failure falls through to Claude Code's own behaviour.

type Conn = { base: string; headers: Record<string, string> }
type Reply = { status: number; text: string }
type Payload = Record<string, unknown>

/** The app's long-polls answer within this; `$.http.fetch` gives up at 30 s. */
const RETRY_MS = 3_000
/** How long a question or permission waits for Glaude before the terminal takes it. */
const WAIT_LIMIT_MS = 120_000
/**
 * How long a permission ask waits before Glaude flags it. In auto mode an ask goes to
 * the classifier, which usually decides within this; a mod can't read the mode, so the
 * card only appears for a call that is still waiting (most likely on you) by then.
 */
const ASK_NOTICE_MS = 6_000
/** Prompts the engine makes itself, which Glaude doesn't show as yours. */
const MACHINE_PROMPTS = new Set(['task-notification', 'auto-continuation', 'observer', 'observer-activity', 'coordinator'])
/** Tools whose terminal dialog asks the person whatever the permission mode. */
const ASKS_ITSELF = new Set(['AskUserQuestion', 'ExitPlanMode'])
/** File tools whose result carries a structuredPatch for Glaude's diff view. */
const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit'])
/** The most diff lines sent per edit; the rest is counted, not shown. */
const PATCH_LINE_LIMIT = 400
/** Session ends after which the process goes on under another session id: /clear, and /resume. */
const CONTINUING_END_REASONS = new Set(['clear', 'resume'])

let conn: Conn | undefined
let cwd = ''
/** Where `claude` was started: what Ghostty reports as the tab's working directory. */
let launchDir = ''
let pid = 0
let tty = ''
/** The `notifications` option: who notifies, as the app needs to know. */
let notifyMode = 'glaude'
let stopped = false
/** Asks not yet flagged, by tool_use_id: cancelled once the call goes ahead. */
const openAsks = new Map<string, Timer>()
/** Asks Glaude is showing a card for, by tool_use_id. */
const flaggedAsks = new Set<string>()

async function connect($: EngineInterface): Promise<Conn | undefined> {
  if (conn) return conn
  try {
    const home = await $.env.get('HOME')
    const port = (await $.fs.read(`${home}/.glaude/port`)).trim()
    const token = (await $.fs.read(`${home}/.glaude/token`)).trim()
    if (!port || !token) return undefined
    conn = {
      base: `http://127.0.0.1:${port}`,
      headers: { 'X-Glaude-Token': token, 'Content-Type': 'application/json' },
    }
    return conn
  } catch {
    return undefined // Glaude isn't installed or running yet
  }
}

/** One request to the app; undefined when it can't be reached (then we re-read port/token). */
async function call($: EngineInterface, method: string, path: string, body?: Payload): Promise<Reply | undefined> {
  const c = await connect($)
  if (!c) return undefined
  try {
    const res = await $.http.fetch(c.base + path, {
      method,
      headers: c.headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    if (res.status === 403) conn = undefined // the app made a new token
    return { status: res.status, text: res.text }
  } catch {
    conn = undefined
    return undefined
  }
}

/** The fields every message to the app carries. */
async function envelope($: EngineInterface, event: string, fields: Payload): Promise<Payload> {
  return {
    session_id: await $.session.id(), cwd, launch_dir: launchDir, pid, tty, notify: notifyMode,
    hook_event_name: event, ...fields,
  }
}

/** Fire-and-forget status update: never holds up Claude. */
function report($: EngineInterface, event: string, fields: Payload = {}) {
  void envelope($, event, fields).then(body => call($, 'POST', '/event', body))
}

/**
 * Puts a question or permission card up in Glaude and waits for it, re-polling under the
 * fetch limit. Undefined when Glaude didn't answer (closed, timed out, terminal chosen).
 */
async function waitForGlaude($: EngineInterface, event: string, fields: Payload, signal: AbortSignal): Promise<Payload | undefined> {
  const request = crypto.randomUUID()
  const cancel = () => { void call($, 'POST', `/cancel?request=${request}`) }
  signal.addEventListener('abort', cancel, { once: true })
  const started = Date.now()
  let res = await call($, 'POST', `/wait?request=${request}`, await envelope($, event, fields))
  while (res?.status === 202 && !signal.aborted && Date.now() - started < WAIT_LIMIT_MS) {
    res = await call($, 'GET', `/wait/next?request=${request}`)
  }
  signal.removeEventListener('abort', cancel)
  if (res?.status === 200 && !signal.aborted) return JSON.parse(res.text) as Payload
  cancel()
  return undefined
}

/** One reply long-poll; schedules the next, whatever happens. A reply becomes a prompt of its own. */
async function pollReplies($: EngineInterface) {
  if (stopped) return
  let delay = RETRY_MS
  try {
    const session = await $.session.id()
    const res = await call($, 'GET', `/reply/next?session=${encodeURIComponent(session)}&cwd=${encodeURIComponent(cwd)}&pid=${pid}`)
    if (res?.status === 200) {
      const { text } = JSON.parse(res.text) as { text?: string }
      if (text) void $.prompt.submit({ text })
    }
    if (res?.status === 200 || res?.status === 204) delay = 0
  } finally {
    // A poll that fails must not end the loop: the session would stop taking replies.
    $.clock.after(delay, () => { void pollReplies($) })
  }
}

/** The claude process's id and terminal, so Glaude can bring the session's own tab forward. */
async function claudeIdentity($: EngineInterface): Promise<{ pid: number; tty: string }> {
  try {
    const { stdout } = await $.process.run(['/bin/sh', '-c', 'echo $PPID; ps -o tty= -p $PPID'], { timeoutMs: 2_000 })
    const [pidLine = '', ttyLine = ''] = stdout.split('\n').map(line => line.trim())
    const name = ttyLine && ttyLine !== '??' ? ttyLine : ''
    return { pid: Number(pidLine) || 0, tty: name ? `/dev/${name.replace(/^\/dev\//, '')}` : '' }
  } catch {
    return { pid: 0, tty: '' }
  }
}

/** Plan limits (5-hour, weekly), context fill and cost, for the panel's header and chips. */
async function usageFields($: EngineInterface): Promise<Payload> {
  try {
    const usage = await $.session.usage()
    return {
      usage: {
        limits: usage.rateLimits.map(l => ({ kind: l.kind, percentUsed: l.percentUsed, resetsAt: l.resetsAt ?? null })),
        contextPercent: usage.context.percent ?? null,
        contextWindow: usage.context.window,
        costUsd: usage.cost?.usd ?? null,
      },
    }
  } catch {
    return {}
  }
}

/** An edit's diff hunks from the tool's result, capped at PATCH_LINE_LIMIT lines. */
function patchFields(tool: string, input: Payload, result: unknown): Payload {
  if (!EDIT_TOOLS.has(tool)) return {}
  type Hunk = { oldStart: number; newStart: number; lines: string[] }
  const output = (result as { result?: { structuredPatch?: Hunk[]; type?: string; content?: string } }).result
  let hunks: Hunk[] = output?.structuredPatch ?? []
  // A new file written whole has no patch: every line is an addition.
  if (!hunks.length && tool === 'Write' && typeof input.content === 'string') {
    const lines = input.content.split('\n')
    if (lines.at(-1) === '') lines.pop() // a trailing newline isn't a line of its own
    hunks = [{ oldStart: 0, newStart: 1, lines: lines.map(line => `+${line}`) }]
  }
  let added = 0
  let removed = 0
  let budget = PATCH_LINE_LIMIT
  const patch: Hunk[] = []
  for (const hunk of hunks) {
    for (const line of hunk.lines) {
      if (line.startsWith('+')) added++
      else if (line.startsWith('-')) removed++
    }
    if (budget > 0) {
      patch.push({ oldStart: hunk.oldStart, newStart: hunk.newStart, lines: hunk.lines.slice(0, budget) })
      budget -= hunk.lines.length
    }
  }
  return { patch, added, removed, patch_truncated: budget < 0 }
}

/** The project's folder name, for notification titles. */
function projectName(): string {
  return (launchDir || cwd).split('/').filter(Boolean).pop() ?? 'Claude Code'
}

/** The call went ahead (it's running, or finished): it no longer waits on you. */
function callProceeded($: EngineInterface, id: string, finished: boolean) {
  openAsks.get(id)?.cancel()
  openAsks.delete(id)
  // A finished call's PostToolUse clears the card; a running one needs telling.
  if (flaggedAsks.delete(id) && !finished) report($, 'ToolRunning', { tool_use_id: id })
}

/** A tool call's own arguments, without the engine's fields. */
function toolInput(e: Payload): Payload {
  const { tool: _tool, tool_use_id: _id, agentId: _agent, consent: _consent, ...input } = e
  return input
}

export const register: Register = (on, options) => {
  const answerPermissions = options.answerPermissions === true
  const mode = typeof options.notifications === 'string' ? options.notifications.trim().toLowerCase() : ''
  notifyMode = mode === 'claude' || mode === 'off' ? mode : 'glaude'

  on('session.start', async ($, e, next) => {
    if (!e.isInteractive) return next(e) // nobody to show a bubble to (claude -p, SDK)
    cwd = e.cwd
    launchDir = (await $.env.get('PWD')) ?? e.cwd
    ;({ pid, tty } = await claudeIdentity($))
    void usageFields($).then(usage => report($, 'SessionStart', usage))
    $.clock.after(0, () => { void pollReplies($) })
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    report($, 'SessionEnd', { reason: e.reason })
    if (!CONTINUING_END_REASONS.has(e.reason)) stopped = true
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    const result = await next(e)
    const machine = MACHINE_PROMPTS.has(e.origin?.kind ?? '')
    if (cwd && !e.isMeta && !e.command && !machine && !('drop' in result && result.drop)) {
      report($, 'UserPromptSubmit', { prompt: e.text })
    }
    return result
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    if (!cwd) return next(e)
    const input = toolInput(e as unknown as Payload)

    if (e.tool === 'AskUserQuestion' && !e.agentId) {
      const answer = await waitForGlaude($, 'Questions', { tool_name: e.tool, tool_input: input }, next.signal)
      if (answer?.answers) {
        // Answered in Glaude: reply for the tool. (Filling `answers` and calling next
        // would still open the terminal dialog.)
        report($, 'PostToolUse', { tool_name: e.tool, tool_input: input })
        return { result: { questions: input.questions, answers: answer.answers } } as never
      }
    }
    if (e.tool === 'ExitPlanMode') report($, 'PlanReady', { tool_name: e.tool })

    const result = await next(e)
    if (e.tool_use_id) callProceeded($, e.tool_use_id, true)
    report($, 'PostToolUse', { tool_name: e.tool, tool_input: input, ...patchFields(e.tool, input, result) })
    return result
  }).catch(($, e, next) => next(e))

  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    // Only a real call (not a query) that is about to ask, for tools whose own dialog
    // isn't covered above.
    if (!cwd || verdict.decision !== 'ask' || !e.tool_use_id || ASKS_ITSELF.has(e.tool)) return verdict
    const fields = { tool_name: e.tool, tool_input: e.input, reason: verdict.reason ?? null }
    if (!answerPermissions) {
      const id = e.tool_use_id
      openAsks.set(id, $.clock.after(ASK_NOTICE_MS, () => {
        if (!openAsks.delete(id)) return
        flaggedAsks.add(id)
        report($, 'PermissionAsk', { ...fields, tool_use_id: id })
      }))
      return verdict
    }
    const answer = await waitForGlaude($, 'Permission', fields, next.signal)
    if (answer?.decision === 'allow') return { ...verdict, decision: 'allow', reason: 'Allowed in Glaude' }
    if (answer?.decision === 'deny') return { ...verdict, decision: 'deny', reason: 'Denied in Glaude' }
    return verdict
  }).catch(($, e, next) => next(e))

  // The terminal draws a run-in-background pill under a call that's running: by then
  // the ask was answered (by you or the auto-mode classifier), so drop its card.
  on('ui.render', { component: 'ToolProgress' }, ($, e, next) => {
    if (e.props.tool_use_id) callProceeded($, e.props.tool_use_id, false)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (cwd && !e.agentId) {
      const usage = await usageFields($)
      report($, 'Stop', { last_assistant_message: e.answer, ...usage })
      if (notifyMode === 'claude') {
        // Through the person's own /config channel; Claude Code already notifies when it
        // waits on them, so only "done" is added here.
        const first = (e.answer ?? '').split('\n').find(line => line.trim()) ?? 'Done'
        void $.ui.notify(first.slice(0, 160), { title: `${projectName()} finished` })
      }
    }
    return result
  })
}
