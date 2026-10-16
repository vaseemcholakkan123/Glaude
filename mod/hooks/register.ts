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
/** Tools whose terminal dialog asks the person whatever the permission mode. */
const ASKS_ITSELF = new Set(['AskUserQuestion', 'ExitPlanMode'])

let conn: Conn | undefined
let cwd = ''
let pid = 0
let stopped = false
/** Asks not yet flagged, by tool_use_id: cancelled once the call goes ahead. */
const openAsks = new Map<string, Timer>()

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
  return { session_id: await $.session.id(), cwd, pid, hook_event_name: event, ...fields }
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

/** One reply long-poll; schedules the next. A reply becomes a prompt of its own. */
async function pollReplies($: EngineInterface) {
  if (stopped) return
  const session = await $.session.id()
  const res = await call($, 'GET', `/reply/next?session=${encodeURIComponent(session)}&cwd=${encodeURIComponent(cwd)}&pid=${pid}`)
  if (res?.status === 200) {
    const { text } = JSON.parse(res.text) as { text?: string }
    if (text) void $.prompt.submit({ text })
  }
  const delay = res?.status === 200 || res?.status === 204 ? 0 : RETRY_MS
  $.clock.after(delay, () => { void pollReplies($) })
}

/** The claude process id, so Glaude can bring the session's terminal to the front. */
async function claudePid($: EngineInterface): Promise<number> {
  try {
    const { stdout } = await $.process.run(['/bin/sh', '-c', 'echo $PPID'], { timeoutMs: 2_000 })
    return Number(stdout.trim()) || 0
  } catch {
    return 0
  }
}

/** A tool call's own arguments, without the engine's fields. */
function toolInput(e: Payload): Payload {
  const { tool: _tool, tool_use_id: _id, agentId: _agent, consent: _consent, ...input } = e
  return input
}

export const register: Register = (on, options) => {
  const answerPermissions = options.answerPermissions === true

  on('session.start', async ($, e, next) => {
    if (!e.isInteractive) return next(e) // nobody to show a bubble to (claude -p, SDK)
    cwd = e.cwd
    pid = await claudePid($)
    report($, 'SessionStart')
    $.clock.after(0, () => { void pollReplies($) })
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    report($, 'SessionEnd', { reason: e.reason })
    if (e.reason !== 'clear') stopped = true // after /clear the session goes on under a new id
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    const result = await next(e)
    if (cwd && !e.isMeta && !e.command && !('drop' in result && result.drop)) {
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
    if (e.tool_use_id) {
      openAsks.get(e.tool_use_id)?.cancel()
      openAsks.delete(e.tool_use_id)
    }
    report($, 'PostToolUse', { tool_name: e.tool, tool_input: input })
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
        if (openAsks.delete(id)) report($, 'PermissionAsk', fields)
      }))
      return verdict
    }
    const answer = await waitForGlaude($, 'Permission', fields, next.signal)
    if (answer?.decision === 'allow') return { ...verdict, decision: 'allow', reason: 'Allowed in Glaude' }
    if (answer?.decision === 'deny') return { ...verdict, decision: 'deny', reason: 'Denied in Glaude' }
    return verdict
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (cwd && !e.agentId) report($, 'Stop', { last_assistant_message: e.answer })
    return result
  })
}
