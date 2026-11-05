import { expect, mock, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

type On = Parameters<TestBody>[1]

// 對話框上方那一列，跟引擎畫它時給的一樣。
const BAND = {
  plugin: 'lookout',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 80,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
} as const

const SURFACES = ['terminal', 'desktop'] as const
const HOME = '/Users/someone'
const ROOT = `${HOME}/Library/Application Support/Lookout`
const BINARY = `${ROOT}/app/lookout`

type World = {
  installed: boolean
  /** 鎖檔裡的 pid；undefined＝沒有鎖檔 */
  lockPid?: number
  /** 那個 pid 現在是哪支程式；undefined＝沒有這個程序 */
  pidCommand?: string
  switchText?: string
  starts: number
  kills: number[]
}

/**
 * 假的世界：一支 Lookout、它的鎖檔與開關檔。真的程序一個都不會碰到 ——
 * 所有 $.process.run 都在這裡被回答掉；沒預期到的指令直接讓測試失敗。
 */
function fakeWorld(on: On, init: Partial<World>): World {
  const world: World = { installed: true, starts: 0, kills: [], ...init }
  const ran = (exitCode: number, stdout = '') => ({
    value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  })
  mock.env(on, { HOME })
  on('process.run', (_, e) => {
    const [cmd, ...args] = e.argv
    if (cmd === '/bin/test') return ran(world.installed && args[1] === BINARY ? 0 : 1)
    if (cmd === '/bin/ps') {
      const alive = world.pidCommand !== undefined && args[1] === String(world.lockPid)
      return alive ? ran(0, `${world.pidCommand}\n`) : ran(1)
    }
    if (cmd === '/bin/kill') {
      world.kills.push(Number(args[0]))
      world.pidCommand = undefined
      return ran(0)
    }
    if (cmd === '/bin/sh' && e.argv.at(-1) === BINARY) {
      world.starts++
      world.lockPid = 4242
      world.pidCommand = BINARY
      return ran(0)
    }
    throw new Error(`unexpected process: ${e.argv.join(' ')}`)
  })
  on('fs.read', (_, e) => {
    const text = e.path === `${ROOT}/instance.lock`
      ? (world.lockPid === undefined ? undefined : `${world.lockPid}\n`)
      : e.path === `${ROOT}/switch` ? world.switchText : undefined
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_, e) => {
    if (e.path !== `${ROOT}/switch`) throw new Error(`unexpected write: ${e.path}`)
    world.switchText = e.text
    return { value: undefined }
  })
  on('command.register', () => ({ value: { command: 'lookout' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  return world
}

const statusText = async (ui: { find: (q: { type: string; text?: RegExp }) => Promise<{ text: string } | undefined> }) =>
  (await ui.find({ type: 'Text', text: /Lookout/ }))?.text

for (const surface of SURFACES) {
  test(`${surface}: 關著時顯示「打開」，按下去打開、再按關掉`, async ($, on) => {
    mock.clock(on)
    const world = fakeWorld(on, { switchText: 'off\n' })
    await $.session.start({ cwd: '/', surface, isInteractive: true })
    expect(world.starts).toBe(0) // 開關是 off：不該自己打開

    const ui = await $.ui.mount({ ...BAND, surface })
    expect(await statusText(ui)).toBe('○ Lookout 關著')
    expect((await ui.find({ type: 'Button', key: 'lookout-toggle' }))?.text).toBe('打開')

    await ui.press({ key: 'lookout-toggle' })
    expect(world.starts).toBe(1)
    expect(await statusText(ui)).toBe('● Lookout 開著')
    expect((await ui.find({ type: 'Button', key: 'lookout-toggle' }))?.text).toBe('關掉')

    await ui.press({ key: 'lookout-toggle' })
    expect(world.kills).toEqual([4242]) // 關的是鎖檔裡那一個
    expect(world.switchText).toBe('off\n') // 關掉要記下來，重新開機才不會又自己打開
    expect(await statusText(ui)).toBe('○ Lookout 關著')
    await ui.unmount()
  })

  test(`${surface}: 開關是 on、視窗沒在跑（剛重開機）→ 自己打開`, async ($, on) => {
    mock.clock(on)
    const world = fakeWorld(on, { switchText: 'on\n' })
    await $.session.start({ cwd: '/', surface, isInteractive: true })
    expect(world.starts).toBe(1)

    const ui = await $.ui.mount({ ...BAND, surface })
    expect(await statusText(ui)).toBe('● Lookout 開著')
    await ui.unmount()
  })

  test(`${surface}: 在別處關掉視窗（⌘Q），5 秒內那一列跟上`, async ($, on) => {
    const clock = mock.clock(on)
    const world = fakeWorld(on, { switchText: 'on\n', lockPid: 4242, pidCommand: BINARY })
    await $.session.start({ cwd: '/', surface, isInteractive: true })
    expect(world.starts).toBe(0) // 已經在跑：不該再開一個
    const ui = await $.ui.mount({ ...BAND, surface })
    expect(await statusText(ui)).toBe('● Lookout 開著')

    world.pidCommand = undefined
    await clock.advance(4_000)
    expect(await statusText(ui)).toBe('● Lookout 開著') // 還沒到 5 秒
    await clock.advance(1_000)
    expect(await statusText(ui)).toBe('○ Lookout 關著')
    await ui.unmount()
  })

  test(`${surface}: 鎖檔裡的 pid 被別的程式重用了 → 當作沒在跑，也不去殺它`, async ($, on) => {
    mock.clock(on)
    const world = fakeWorld(on, { switchText: 'off\n', lockPid: 4242, pidCommand: '/usr/bin/vim' })
    await $.session.start({ cwd: '/', surface, isInteractive: true })
    const ui = await $.ui.mount({ ...BAND, surface })
    expect(await statusText(ui)).toBe('○ Lookout 關著')
    expect(world.kills).toEqual([])
    await ui.unmount()
  })

  test(`${surface}: 還沒跑 install.sh → 說還沒安裝，不畫按鈕`, async ($, on) => {
    mock.clock(on)
    const world = fakeWorld(on, { installed: false, switchText: 'on\n' })
    await $.session.start({ cwd: '/', surface, isInteractive: true })
    expect(world.starts).toBe(0)
    const ui = await $.ui.mount({ ...BAND, surface })
    expect(await statusText(ui)).toBe('○ Lookout 還沒安裝 —— 在它的資料夾裡跑 ./install.sh')
    expect(await ui.find({ type: 'Button', key: 'lookout-toggle' })).toBe(undefined)
    await ui.unmount()
  })

  test(`${surface}: Claude 在問你問題時，那一列讓給它`, async ($, on) => {
    mock.clock(on)
    fakeWorld(on, { switchText: 'on\n', lockPid: 4242, pidCommand: BINARY })
    on('ui.render', ($, e) => {
      const { Text } = $.ui.resolve(e)
      return <Text>survey</Text>
    })
    await $.session.start({ cwd: '/', surface, isInteractive: true })
    const ui = await $.ui.mount({ ...BAND, surface, props: { ...BAND.props, hasSurvey: true } })
    expect(await ui.find({ type: 'Button', key: 'lookout-toggle' })).toBe(undefined)
    expect((await ui.find({ type: 'Text', text: /survey/ }))?.text).toBe('survey')
    await ui.unmount()
  })
}
