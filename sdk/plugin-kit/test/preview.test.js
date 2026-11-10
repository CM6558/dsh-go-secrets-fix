import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync, existsSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { test } from 'node:test'
import { prepare, main } from '../bin/preview.mjs'

function files(t, value = { type: 'text', text: 'Preview' }) {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-native-preview-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const view = join(dir, 'view.json')
  const data = join(dir, 'data.json')
  const out = join(dir, 'new-output')
  writeFileSync(view, JSON.stringify(value))
  writeFileSync(data, '{"count":42}')
  return { dir, view, data, out }
}

test('panel diagnostics and snapshot use the supplied data, width and text scale', t => {
  const f = files(t, { type: 'metric', label: 'Count', value: { $: 'data.count' } })
  const job = prepare([f.view, '--data', f.data, '--out', f.out, '--width', '320', '--scale', '1.3'])
  assert.equal(job.request.budget, 'panel')
  assert.equal(job.request.width, 320)
  assert.equal(job.request.scale, 1.3)
  assert.deepEqual(job.report.views[0].issues, [])
  assert.deepEqual(job.request.data, { count: 42 })
  assert.equal(existsSync(f.out), false, 'preflight must not write output')
})

test('wrapped tool cards do not acquire an unsupported data model', t => {
  const f = files(t, { 'dsh-go/view': { type: 'metric', label: 'Count', value: { $: 'data.count' } } })
  const job = prepare([f.view, '--data', f.data, '--out', f.out])
  assert.equal(job.request.budget, 'toolCard')
  assert.equal(job.request.data, null)
  assert.ok(job.report.views[0].issues.some(i => i.path === 'view.value'))
})

test('invalid JSON, excessive input and invalid rendering options fail before output', t => {
  const f = files(t)
  for (const args of [['--width', '239'], ['--height', '2401'], ['--scale', 'NaN'], ['--scale', '2.1'], ['--budget', '__proto__'], ['--theme', 'other'], ['--lang', 'fr'], ['--load']]) {
    assert.throws(() => prepare([f.view, '--out', f.out, ...args]))
  }
  writeFileSync(f.view, '{not-json')
  assert.throws(() => prepare([f.view, '--out', f.out]), SyntaxError)
  writeFileSync(f.view, ' '.repeat(1024 * 1024 + 1))
  assert.throws(() => prepare([f.view, '--out', f.out]), /1 MiB/)
  assert.equal(existsSync(f.out), false)
})

test('root errors return the checker failure without launching Flutter or writing output', t => {
  const f = files(t, { type: 'unknown' })
  let calls = 0
  const code = main([f.view, '--out', f.out], () => { calls++; return { status: 0 } })
  assert.equal(code, 2)
  assert.equal(calls, 0)
  assert.equal(existsSync(f.out), false)
})

test('existing output is not overwritten and never launches Flutter', t => {
  const f = files(t)
  writeFileSync(f.out, 'keep')
  let calls = 0
  const code = main([f.view, '--out', f.out], () => { calls++; return { status: 0 } })
  assert.equal(code, 3)
  assert.equal(calls, 0)
})

test('a failed process or missing PNG cannot be reported as a rendered preview', t => {
  const f = files(t)
  const code = main([f.view, '--out', f.out], () => ({ status: 0 }))
  assert.equal(code, 3)
  assert.ok(existsSync(join(f.out, 'request.json')))
  const second = main([f.view, '--out', join(f.dir, 'second-output')], () => ({ status: 1 }))
  assert.equal(second, 3)
})
