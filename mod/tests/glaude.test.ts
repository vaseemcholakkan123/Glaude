import type { On } from 'claude-code'
import type { MockClock } from 'claude-code/testing'
import { expect, mock, test } from 'claude-code/testing'

// A stand-in for Glaude.app beneath the plugin: it answers the mod's localhost
// requests, the files and command the mod reads, and records what it was sent.
type FakeApp = {
  events: Record<string, unknown>[]
  waits: Record<string, unknown>[]
  replies: string[]
  answer?: Record<string, unknown>
  running: boolean
  submitted: string[]
  clock: MockClock
}

const PROJECT = { cwd: '/work/project', surface: 'terminal' as const, isInteractive: true }

function fakeApp(on: On): FakeApp {
  const clock = mock.clock(on)
  const app: FakeApp = { events: [], waits: [], replies: [], running: true, submitted: [], clock }
  mock.env(on, { HOME: '/home/me' })
  on('fs.read', ($, e) => ({ value: e.path.endsWith('/.glaude/port') ? '47821\n' : 'secret-token\n' }))
  on('process.run', () => ({ value: { exitCode: 0, stdout: '4242\n', stderr: '' } }) as never)
  on('session.id', () => ({ value: 'session-1' }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('prompt.submit', ($, e) => {
    app.submitted.push(e.text)
    return { text: e.text }
  })
  on('http.fetch', async ($, e) => {
    if (!app.running) throw new Error('connection refused')
    const url = new URL(e.url)
    const body = e.init?.body ? (JSON.parse(e.init.body) as Record<string, unknown>) : {}
    const ok = (status: number, json?: unknown) =>
      ({ value: { status, ok: status < 300, headers: {}, text: json === undefined ? '' : JSON.stringify(json) } }) as never
    switch (url.pathname) {
      case '/event':
        app.events.push(body)
        return ok(200)
      case '/reply/next': {
        const text = app.replies.shift()
        if (text) return ok(200, { text })
        await clock.sleep(25_000) // the app holds the poll open
        return ok(204)
      }
      case '/wait':
        app.waits.push(body)
        return app.answer ? ok(200, app.answer) : ok(204)
      case '/cancel':
        return ok(200)
      default:
        return ok(404)
    }
  })
  return app
}

function eventNames(app: FakeApp) {
  return app.events.map(e => e.hook_event_name)
}

test('a session reports itself, with the claude pid', async ($, on) => {
  const app = fakeApp(on)
  await $.session.start(PROJECT)
  await app.clock.settle()
  expect(app.events[0]).toEqual(expect.objectContaining({
    hook_event_name: 'SessionStart', session_id: 'session-1', cwd: '/work/project', pid: 4242,
  }))
})

test('a reply typed in Glaude is submitted as a prompt', async ($, on) => {
  const app = fakeApp(on)
  app.replies.push('please also update the README')
  await $.session.start(PROJECT)
  await app.clock.settle()
  expect(app.submitted).toContain('please also update the README')
})

test('prompts and finished turns are reported', async ($, on) => {
  const app = fakeApp(on)
  await $.session.start(PROJECT)
  await $.prompt.submit({ text: 'fix the build' } as never)
  await app.clock.settle()
  expect(app.events).toContainEqual(expect.objectContaining({ hook_event_name: 'UserPromptSubmit', prompt: 'fix the build' }))
})

test('a question answered in Glaude answers the tool without the terminal dialog', async ($, on) => {
  const app = fakeApp(on)
  app.answer = { answers: { 'Which database?': 'Postgres' } }
  let dialogShown = false
  on('tool.call', { tool: 'AskUserQuestion' }, () => {
    dialogShown = true
    return { result: { questions: [], answers: {} } } as never
  })
  await $.session.start(PROJECT)
  const questions = [{ question: 'Which database?', header: 'DB', multiSelect: false,
    options: [{ label: 'Postgres', description: '' }, { label: 'SQLite', description: '' }] }]
  const result = await $.tool.call({ tool: 'AskUserQuestion', questions } as never)
  expect(dialogShown).toBe(false)
  expect((result as { result: { answers: unknown } }).result.answers).toEqual({ 'Which database?': 'Postgres' })
  expect(app.waits[0]).toEqual(expect.objectContaining({ hook_event_name: 'Questions' }))
})

test('when Glaude is not running, everything falls through to Claude Code', async ($, on) => {
  const app = fakeApp(on)
  app.running = false
  let dialogShown = false
  on('tool.call', { tool: 'AskUserQuestion' }, () => {
    dialogShown = true
    return { result: { questions: [], answers: { q: 'typed in terminal' } } } as never
  })
  await $.session.start(PROJECT)
  await $.tool.call({ tool: 'AskUserQuestion', questions: [] } as never)
  expect(dialogShown).toBe(true)
  expect(eventNames(app)).toEqual([])
})

// The permission path itself needs a real call's tool_use_id, which only a session's
// loop sets; it is checked live (see CONTRIBUTING.md). Queries must stay silent.
test('a permission query (no real call) is not reported or held', async ($, on) => {
  const app = fakeApp(on)
  on('tool.check', () => ({ decision: 'ask', reason: 'Bash needs approval' }))
  await $.session.start(PROJECT)
  const verdict = await $.tool.check({ tool: 'Bash', input: { command: 'rm -rf build' } })
  await app.clock.settle()
  expect(verdict.decision).toBe('ask')
  expect(app.waits).toEqual([])
  expect(eventNames(app)).not.toContain('PermissionAsk')
})

test('a background-task notification is not shown as your prompt', async ($, on) => {
  const app = fakeApp(on)
  await $.session.start(PROJECT)
  await $.prompt.submit({ text: '<task-notification>done</task-notification>', origin: { kind: 'task-notification' }, wait: false } as never)
  await $.prompt.submit({ text: 'typed by you', origin: { kind: 'composer' }, wait: false } as never)
  await app.clock.settle()
  const prompts = app.events.filter(e => e.hook_event_name === 'UserPromptSubmit').map(e => e.prompt)
  expect(prompts).toEqual(['typed by you'])
})
