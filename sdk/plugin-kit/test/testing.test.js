import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createTestHost } from '../lib/testing.js'

const pkg = (dshGo) => ({ name: 'demo', version: '1.0.0', dshGo })

const manifest = {
  v: 1,
  title: { zh: '演示', en: 'Demo' },
  wants: ['clipboard'],
  contributes: {
    'composer.actions': [
      { id: 'static', label: '静态', effect: { type: 'insert', text: 'hi' } },
      { id: 'dyn', label: '动态' },
    ],
    'composer.strip': [{ id: 'line', panel: 'main' }],
    panels: [{ id: 'main', title: '面板' }],
  },
}

test('ready flags and runtime issues follow registrations', () => {
  const host = createTestHost({ pkg: pkg(manifest), dir: '/nonexistent' })
  let row = host.contributions()
  assert.deepEqual(row.issues.map((i) => [i.path, i.code]), [
    ['/dshGo/contributes/composer.actions/1', 'no-handler'],
    ['/dshGo/contributes/panels/0', 'no-handler'],
  ])
  host.ctx.inject(['dshGo'], (ctx) => {
    ctx.dshGo.on('dyn', () => ({ toast: 'ok' }))
    ctx.dshGo.panel('main', { view: { type: 'text', text: 'x' } })
    ctx.dshGo.on('nope', () => {})
  })
  row = host.contributions()
  assert.deepEqual(row.issues.map((i) => [i.path, i.code]), [['/runtime/nope', 'undeclared']])
  assert.equal(row.contributes['composer.actions'][1].ready, true)
})

test('invoke: shorthand expands, bad effects are dropped with an issue, errors carry status', async () => {
  const host = createTestHost({ pkg: pkg(manifest), dir: '/nonexistent' })
  host.ctx.inject(['dshGo'], (ctx) => {
    ctx.dshGo.on('dyn', (scope) => ({ insert: scope.clipboard, link: 'http://insecure.example' }))
  })
  const r = await host.invoke('dyn', { context: { clipboard: 'abc', draft: 'dropped' } })
  assert.deepEqual(r.effects, [{ type: 'insert', text: 'abc' }])
  assert.equal(r.issues[0].code, 'bad-effect')
  await assert.rejects(host.invoke('static'), { status: 409, code: 'no-handler' })
  await assert.rejects(host.invoke('missing'), { status: 404 })
})

test('a throwing handler is a 500 plugin-error and a violation', async () => {
  const host = createTestHost({ pkg: pkg(manifest), dir: '/nonexistent' })
  host.ctx.inject(['dshGo'], (ctx) => ctx.dshGo.on('dyn', () => { throw new Error('boom') }))
  await assert.rejects(host.invoke('dyn'), { status: 500, code: 'plugin-error' })
  assert.equal(host.violations.length, 1)
})

test('subscribe: strip values are cleaned like the bridge does', () => {
  const host = createTestHost({ pkg: pkg(manifest), dir: '/nonexistent' })
  host.ctx.inject(['dshGo'], (ctx) => ctx.dshGo.strip('line', (_s, emit) => {
    emit({ text: '一二三四五六七八九十一二三四五六七八九十一二三四五六', tone: 'loud', icon: 'BAD' })
  }))
  const feed = host.subscribe('line')
  assert.deepEqual(feed.data, { text: '一二三四五六七八九十一二三四五六七八九十一二三四' })
})

test('view: static object or function, with stats', async () => {
  const host = createTestHost({ pkg: pkg(manifest), dir: '/nonexistent' })
  host.ctx.inject(['dshGo'], (ctx) => ctx.dshGo.panel('main', { view: (scope, caps) => ({ type: 'text', text: `${scope.sessionId} ${caps.locale}` }) }))
  const r = await host.view('main', { sessionId: 's' })
  assert.deepEqual(r.view, { type: 'text', text: 's zh-CN' })
  assert.deepEqual(r.stats, { bytes: 32, nodes: 1, depth: 1 })
})

test('deferred results: pending at once, done later, only the deferred whitelist', async () => {
  const host = createTestHost({ pkg: pkg(manifest), dir: '/nonexistent' })
  host.ctx.inject(['dshGo'], (ctx) => ctx.dshGo.on('dyn', (scope) => ({
    pending: { label: '处理中', timeoutMs: 999_999 },
    result: async () => [{ insert: scope.clipboard }, { type: 'command', name: 'compact' }],
  })))
  const r = await host.invoke('dyn', { context: { clipboard: 'abc' } })
  assert.deepEqual(r.effects, [])
  assert.deepEqual({ label: r.pending.label, timeoutMs: r.pending.timeoutMs }, { label: '处理中', timeoutMs: 60000 }, 'timeout clamped to 60 s')
  const settled = await r.settled
  assert.equal(settled.t, 'done')
  assert.deepEqual(settled.effects, [{ type: 'insert', text: 'abc' }])
  assert.match(settled.issues[0].message, /not allowed in a deferred result/)
})

test('deferred results: timeout aborts the work; at most 2 pending', async () => {
  const host = createTestHost({ pkg: pkg(manifest), dir: '/nonexistent' })
  let aborted = 0
  host.ctx.inject(['dshGo'], (ctx) => ctx.dshGo.on('dyn', () => ({
    pending: { timeoutMs: 1000 },
    result: (signal) => new Promise((resolve) => signal.addEventListener('abort', () => { aborted++; resolve({ toast: 'late' }) })),
  })))
  const a = await host.invoke('dyn')
  await host.invoke('dyn')
  await assert.rejects(host.invoke('dyn'), { status: 429, code: 'too-many-pending' })
  assert.deepEqual(await a.settled, { t: 'void', reason: 'timeout' })
  host.dispose()
  assert.equal(aborted, 2)
})

test('strip and panel data functions get caps with the locale', () => {
  const host = createTestHost({ pkg: pkg(manifest), dir: '/nonexistent', caps: { locale: 'en-US' } })
  host.ctx.inject(['dshGo'], (ctx) => ctx.dshGo.strip('line', (_s, emit, caps) => emit({ text: caps.locale })))
  assert.deepEqual(host.subscribe('line').data, { text: 'en-US' })
})
