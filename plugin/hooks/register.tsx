import { atom, read, update } from 'claude-code'
import type { EngineInterface as Engine, Register } from 'claude-code'

import type { Status } from '../types'

// Lookout 視窗本身是另一支程式（install.sh 裝的）；這個 mod 只負責開、關、和顯示它現在開著沒有。
// 路徑都從 HOME 算出來，所以誰裝都一樣能用。
const APP_SUBDIR = 'Library/Application Support/Lookout'
const PROCESS_NAME = 'lookout'

const statusAtom = atom({ plugin: 'lookout', key: 'status' } as const, 'unknown' as Status)
const busyAtom = atom({ plugin: 'lookout', key: 'busy' } as const, false)

type Paths = { binary: string; lockFile: string; switchFile: string }

async function paths($: Engine): Promise<Paths> {
  const home = (await $.env.get('HOME')) ?? ''
  const root = `${home}/${APP_SUBDIR}`
  return {
    binary: `${root}/app/${PROCESS_NAME}`,
    // Lookout 啟動時拿這個檔的鎖，並把自己的 pid 寫進去
    lockFile: `${root}/instance.lock`,
    // 開關狀態檔，由 Lookout 自己維護：打開＝on、你關掉它＝off、關機不算你關的（維持 on）
    switchFile: `${root}/switch`,
  }
}

async function readText($: Engine, path: string): Promise<string | undefined> {
  try {
    return await $.fs.read(path)
  } catch {
    return undefined // 檔案不存在
  }
}

async function isInstalled($: Engine, p: Paths): Promise<boolean> {
  return (await $.process.run(['/bin/test', '-x', p.binary])).exitCode === 0
}

/**
 * 正在跑的那一個 Lookout 的 pid；沒在跑就是 undefined。
 * 用鎖檔裡的 pid，再確認那個 pid 真的是 lookout —— 不用 pgrep／pkill 比對名稱，
 * 免得認錯或誤殺別的同名程式；pid 被別的程式重用時也認得出來。
 */
async function runningPid($: Engine, p: Paths): Promise<number | undefined> {
  const pid = Number.parseInt((await readText($, p.lockFile)) ?? '', 10)
  if (!Number.isInteger(pid) || pid <= 0) return undefined
  const ps = await $.process.run(['/bin/ps', '-p', String(pid), '-o', 'comm='])
  const command = ps.stdout.trim()
  return ps.exitCode === 0 && command.split('/').pop() === PROCESS_NAME ? pid : undefined
}

async function currentStatus($: Engine, p: Paths): Promise<Status> {
  if ((await runningPid($, p)) !== undefined) return 'running'
  return (await isInstalled($, p)) ? 'stopped' : 'missing'
}

/** 等到「有沒有在跑」變成想要的樣子，最多 4 秒。 */
async function waitFor($: Engine, p: Paths, running: boolean): Promise<boolean> {
  for (let i = 0; i < 20; i++) {
    if (((await runningPid($, p)) !== undefined) === running) return true
    await $.clock.sleep(200)
  }
  return false
}

/**
 * 用 nohup 丟到背景：$.process.spawn 的子程序會跟著 session 結束一起被關掉，
 * Lookout 不該因為你關掉一個聊天就消失（它啟動時也會 setsid() 脫離 Claude 的 process group）。
 * 路徑當成參數傳給 sh，不拼進指令字串，路徑裡有空白或引號都不會出事。
 */
async function start($: Engine, p: Paths): Promise<boolean> {
  if ((await runningPid($, p)) !== undefined) return true
  if (!(await isInstalled($, p))) return false
  await $.process.run(['/bin/sh', '-c', 'nohup "$1" >/dev/null 2>&1 &', 'sh', p.binary])
  return waitFor($, p, true)
}

/** 先把開關寫成 off 再關：用 SIGTERM 結束時，Lookout 自己來不及寫。 */
async function stop($: Engine, p: Paths): Promise<boolean> {
  await $.fs.write(p.switchFile, 'off\n')
  const pid = await runningPid($, p)
  if (pid === undefined) return true
  await $.process.run(['/bin/kill', String(pid)])
  return waitFor($, p, false)
}

/** 重新量一次，寫進 atom；開關列會跟著重畫。只在值真的變了才寫，免得每 5 秒重畫一次。 */
async function refresh($: Engine): Promise<Status> {
  const now = await currentStatus($, await paths($))
  if ((await read($, statusAtom)) !== now) await update($, statusAtom, () => now)
  return now
}

const NOT_INSTALLED = '還沒安裝 Lookout：請先在 Lookout 的資料夾裡跑 ./install.sh（見 README）'

/** 開關列的按鈕和 /lookout 共用這一段，兩邊的行為才不會分岔。回傳要給人看的一句話。 */
async function setRunning($: Engine, turnOn: boolean): Promise<{ ok: boolean; text: string }> {
  await update($, busyAtom, () => true)
  try {
    const p = await paths($)
    if (turnOn) {
      if (!(await isInstalled($, p))) return { ok: false, text: NOT_INSTALLED }
      const ok = await start($, p)
      return { ok, text: ok ? 'Lookout 打開了。重新開機後，一用 Claude 就會自動打開' : `打不開 Lookout：${p.binary} 沒有跑起來` }
    }
    const ok = await stop($, p)
    return { ok, text: ok ? 'Lookout 關掉了' : '關不掉 Lookout：程序還在，請直接在它的視窗按 ⌘Q' }
  } finally {
    await refresh($)
    await update($, busyAtom, () => false)
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: 'lookout',
      description: '打開或關掉 Lookout 監看視窗（on／off／status，不加就是切換）',
    })
    // 開關是 on、視窗卻沒在跑 —— 通常就是剛重新開機：把它打開。
    const p = await paths($)
    if ((await readText($, p.switchFile))?.trim() === 'on') await start($, p)
    await refresh($)
    // 你也可能直接關掉視窗（⌘Q），或在別的聊天按了開關：開關列要跟上。
    $.clock.every(5_000, () => {
      void refresh($)
    })
    return started
  })

  // 對話框上方那一列：狀態＋一顆按鈕。可以用那一列右邊的 [-] 收起來。
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const status = await read($, statusAtom)
    // Claude 在問你問題時，那一列讓給它；還沒查過狀態時先不畫。
    if (e.props.hasSurvey || status === 'unknown') return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    if (status === 'missing') {
      return (
        <Box gap={1}>
          <Text dimColor>○ Lookout 還沒安裝 —— 在它的資料夾裡跑 ./install.sh</Text>
        </Box>
      )
    }

    const running = status === 'running'
    const busy = await read($, busyAtom)
    return (
      <Box gap={1}>
        <Text dimColor={!running}>{running ? '● Lookout 開著' : '○ Lookout 關著'}</Text>
        {busy ? (
          <Text dimColor>處理中…</Text>
        ) : (
          <Button
            key="lookout-toggle"
            label={running ? '關掉' : '打開'}
            onPress={() => {
              void setRunning($, !running).then(r => {
                if (!r.ok) $.ui.toast(r.text)
              })
            }}
          />
        )}
      </Box>
    )
  })

  on('command.run', { command: 'lookout' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    const status = await refresh($)
    if (arg === 'status') {
      return { text: status === 'running' ? 'Lookout 開著' : status === 'missing' ? NOT_INSTALLED : 'Lookout 關著' }
    }

    const running = status === 'running'
    const turnOn = arg === 'on' ? true : arg === 'off' ? false : arg === '' ? !running : undefined
    if (turnOn === undefined) return { text: `看不懂「${arg}」：用 /lookout、/lookout on、/lookout off 或 /lookout status` }
    return { text: (await setRunning($, turnOn)).text }
  })
}
