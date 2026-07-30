import { spawn, type ChildProcess, execFile } from 'child_process'
import { promisify } from 'util'
import { join } from 'path'
import { tmpdir } from 'os'
import { writeFile, unlink } from 'fs/promises'
import { log } from '../logger.js'
import { childEnv } from '../child-env.js'
import { resolveRuntimeFile } from '../paths.js'
import type { ButtonType } from '../types.js'

const execFileAsync = promisify(execFile)

// Every simctl call gets a deadline: a wedged CoreSimulator must surface as a
// tool error, not an MCP call that hangs forever.
const SIMCTL_TIMEOUT_MS = 15_000

const IDB_PATH = resolveRuntimeFile('python', 'bin', 'idb') ?? 'idb'
const IDB_COMPANION_PATH = resolveRuntimeFile('idb-companion', 'bin', 'idb_companion')

export async function resolveBootedUdid(): Promise<string> {
  const { stdout } = await execFileAsync('xcrun', ['simctl', 'list', 'devices', 'booted', '-j'], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  const data = JSON.parse(stdout)
  for (const runtime of Object.values(data.devices) as { udid: string; state: string }[][]) {
    for (const device of runtime) {
      if (device.state === 'Booted') {
        return device.udid
      }
    }
  }
  throw new Error('No booted simulator found')
}

function parseSimctlAppList(raw: string): { bundleId: string; name: string; type: 'System' | 'User' }[] {
  const apps: { bundleId: string; name: string; type: 'System' | 'User' }[] = []
  const entryRegex = /"([^"]+)"\s*=\s*\{([^}]*(?:\{[^}]*\}[^}]*)*)\}/g
  let match
  while ((match = entryRegex.exec(raw)) !== null) {
    const bundleId = match[1]
    const block = match[2]
    const nameMatch = block.match(/CFBundleDisplayName\s*=\s*(?:"([^"]+)"|([^;]+));/)
    const typeMatch = block.match(/ApplicationType\s*=\s*(\w+);/)
    const name = (nameMatch?.[1] ?? nameMatch?.[2] ?? bundleId).trim()
    const type = typeMatch?.[1] === 'User' ? 'User' : 'System'
    apps.push({ bundleId, name, type })
  }
  return apps
}

export class IDBClient {
  private static instances: Map<string, IDBClient> = new Map()
  private udid: string
  private shellProcess: ChildProcess | null = null
  private isShuttingDown = false
  private companionKillAttempts = 0
  private static readonly MAX_COMPANION_KILL_ATTEMPTS = 5

  private constructor(udid: string) {
    this.udid = udid
  }

  private resolvedUdid: string | null = null

  private async getResolvedUdid(): Promise<string> {
    if (this.resolvedUdid) return this.resolvedUdid
    if (this.udid === 'booted') {
      this.resolvedUdid = await resolveBootedUdid()
      log('IDBClient', 'log', `Resolved "booted" -> ${this.resolvedUdid}`)
    } else {
      this.resolvedUdid = this.udid
    }
    return this.resolvedUdid
  }

  static getInstance(udid: string = 'booted'): IDBClient {
    if (!IDBClient.instances.has(udid)) {
      IDBClient.instances.set(udid, new IDBClient(udid))
    }
    return IDBClient.instances.get(udid)!
  }

  private async startShell(): Promise<void> {
    if (this.shellProcess || this.isShuttingDown) return

    log('IDBClient', 'log', `Starting idb shell for ${this.udid}...`)
    const resolvedUdid = await this.getResolvedUdid()

    const args: string[] = []
    if (IDB_COMPANION_PATH) {
      args.push('--companion-path', IDB_COMPANION_PATH)
    }
    args.push('shell', '--no-prompt', '--udid', resolvedUdid)

    log('IDBClient', 'log', `IDB command - ${IDB_PATH} ${args.join(' ')}`)

    const proc = spawn(IDB_PATH, args, { stdio: ['pipe', 'pipe', 'pipe'] })
    this.shellProcess = proc

    proc.stderr?.on('data', (data: Buffer) => {
      const text = data.toString()
      log('IDBClient', 'log', `[${this.udid}] stderr: ${text.trim()}`)

      if (text.includes('Connection refused')) {
        this.companionKillAttempts++
        if (this.companionKillAttempts > IDBClient.MAX_COMPANION_KILL_ATTEMPTS) {
          log('IDBClient', 'error', `[${this.udid}] Companion connection refused after ${IDBClient.MAX_COMPANION_KILL_ATTEMPTS} attempts`)
          return
        }
        log('IDBClient', 'warn', `[${this.udid}] Companion connection refused (attempt ${this.companionKillAttempts}/${IDBClient.MAX_COMPANION_KILL_ATTEMPTS}) — restarting shell`)
        proc.kill('SIGTERM')
        if (this.shellProcess === proc) this.shellProcess = null
        execFileAsync(IDB_PATH, ['kill'])
          .catch(e => log('IDBClient', 'log', `[${this.udid}] idb kill error: ${e}`))
          .then(() => new Promise(resolve => setTimeout(resolve, 2000)))
          .then(() => this.startShell())
      }
    })

    proc.on('error', (error) => {
      log('IDBClient', 'error', `[${this.udid}] Shell process error: ${error}`)
      if (this.shellProcess === proc) this.shellProcess = null
    })

    proc.on('exit', (code, signal) => {
      log('IDBClient', 'log', `[${this.udid}] Shell exited code=${code} signal=${signal}`)
      if (this.shellProcess === proc) this.shellProcess = null
    })

    await new Promise(resolve => setTimeout(resolve, 300))
    log('IDBClient', 'log', `idb shell started for ${this.udid}`)
  }

  private async runInShell(args: string): Promise<void> {
    if (this.isShuttingDown) throw new Error('IDB client is shutting down')
    if (!this.shellProcess) await this.startShell()
    if (!this.shellProcess?.stdin) throw new Error('Shell process not available')
    log('IDBClient', 'log', `[${this.udid}] Executing: ${args}`)
    this.shellProcess.stdin.write(args + '\n')
  }

  // Argument array, never a shell string: udid and tool parameters are
  // caller-controlled and must not be interpreted by a shell.
  private async runDirect(args: string[]): Promise<string> {
    const resolvedUdid = await this.getResolvedUdid()
    const fullArgs = [
      ...(IDB_COMPANION_PATH ? ['--companion-path', IDB_COMPANION_PATH] : []),
      ...args,
      '--udid', resolvedUdid,
    ]
    log('IDBClient', 'log', `[${this.udid}] Running direct: ${IDB_PATH} ${fullArgs.join(' ')}`)
    const { stdout, stderr } = await execFileAsync(IDB_PATH, fullArgs, { env: childEnv() })
    if (stderr) log('IDBClient', 'log', `[${this.udid}] stderr: ${stderr}`)
    return stdout.trim()
  }

  async shutdown(): Promise<void> {
    if (this.isShuttingDown) return
    log('IDBClient', 'log', `[${this.udid}] Shutting down...`)
    this.isShuttingDown = true

    if (this.shellProcess) {
      this.shellProcess.stdin?.end()
      this.shellProcess.kill('SIGTERM')
      await new Promise(resolve => setTimeout(resolve, 1000))
      if (this.shellProcess && !this.shellProcess.killed) {
        this.shellProcess.kill('SIGKILL')
      }
      this.shellProcess = null
    }

    IDBClient.instances.delete(this.udid)
    log('IDBClient', 'log', `[${this.udid}] Shutdown complete`)
  }

  async tap(x: number, y: number, duration?: number): Promise<void> {
    let args = `ui tap ${x} ${y}`
    if (duration !== undefined) args += ` --duration ${duration}`
    args += ' --json'
    await this.runInShell(args)
  }

  async swipe(fromX: number, fromY: number, toX: number, toY: number, duration?: number, delta?: number): Promise<void> {
    let args = `ui swipe ${fromX} ${fromY} ${toX} ${toY}`
    if (duration !== undefined) args += ` --duration ${duration}`
    if (delta !== undefined) args += ` --delta ${delta}`
    args += ' --json'
    await this.runInShell(args)
  }

  async pressButton(button: ButtonType, duration?: number): Promise<void> {
    if (button === 'VOLUME_UP' || button === 'VOLUME_DOWN') {
      throw new Error(`${button} is only supported on physical devices via WebDriverAgent; simulators have no hardware volume buttons idb can press.`)
    }
    let args = `ui button ${button}`
    if (duration !== undefined) args += ` --duration ${duration}`
    args += ' --json'
    await this.runInShell(args)
  }

  async inputText(text: string): Promise<void> {
    await this.runInShell(`ui text ${JSON.stringify(text)} --json`)
  }

  async pressKey(key: number | string, duration?: number): Promise<void> {
    if (typeof key === 'string') {
      await this.inputText(key)
      return
    }
    let args = `ui key ${key}`
    if (duration !== undefined) args += ` --duration ${duration}`
    args += ' --json'
    await this.runInShell(args)
  }

  async pressKeySequence(keySequence: (number | string)[]): Promise<void> {
    const keys = keySequence.join(' ')
    await this.runInShell(`ui key-sequence ${keys} --json`)
  }

  async describeAll(nested?: boolean): Promise<unknown> {
    const args = ['ui', 'describe-all', '--json']
    if (nested) args.push('--nested')

    let output = ''
    try {
      output = await this.runDirect(args)
      const jsonMatch = output.match(/[{[][\s\S]*[}\]]/)
      if (jsonMatch) return JSON.parse(jsonMatch[0])
      return JSON.parse(output)
    } catch (error) {
      throw new Error(`Failed to parse UI description. Raw output: ${output.substring(0, 300)}`)
    }
  }

  async describePoint(x: number, y: number, nested?: boolean): Promise<unknown> {
    const args = ['ui', 'describe-point', String(Math.round(x)), String(Math.round(y)), '--json']
    if (nested) args.push('--nested')

    let output = ''
    try {
      output = await this.runDirect(args)
      const jsonMatch = output.match(/[{[][\s\S]*[}\]]/)
      if (jsonMatch) return JSON.parse(jsonMatch[0])
      return JSON.parse(output)
    } catch (error) {
      throw new Error(`Failed to parse UI description at point (${x}, ${y}). Raw output: ${output.substring(0, 300)}`)
    }
  }

  async screenshot(): Promise<Buffer> {
    const resolvedUdid = await this.getResolvedUdid()
    const filePath = join(tmpdir(), `agentcontroller-idb-screenshot-${Date.now()}.png`)
    await execFileAsync('xcrun', ['simctl', 'io', resolvedUdid, 'screenshot', '--type=png', filePath], {
      env: childEnv(),
      timeout: SIMCTL_TIMEOUT_MS,
    })
    const { readFile } = await import('fs/promises')
    const buffer = await readFile(filePath)
    await unlink(filePath).catch(() => {})
    return buffer
  }

  async listApps(): Promise<{ bundleId: string; name: string; type: 'System' | 'User' }[]> {
    const resolvedUdid = await this.getResolvedUdid()
    const { stdout } = await execFileAsync('xcrun', ['simctl', 'listapps', resolvedUdid], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
    return parseSimctlAppList(stdout)
  }

  async launch(bundleId: string): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'launch', resolvedUdid, bundleId], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async terminateApp(bundleId: string): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'terminate', resolvedUdid, bundleId], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async openUrl(url: string): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'openurl', resolvedUdid, url], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async installApp(appPath: string): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'install', resolvedUdid, appPath], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async uninstallApp(bundleId: string): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'uninstall', resolvedUdid, bundleId], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async getClipboard(): Promise<string> {
    const resolvedUdid = await this.getResolvedUdid()
    const { stdout } = await execFileAsync('xcrun', ['simctl', 'pbpaste', resolvedUdid], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
    return stdout
  }

  async setClipboard(content: string): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    // simctl pbcopy reads the payload from stdin.
    await new Promise<void>((resolve, reject) => {
      const proc = spawn('xcrun', ['simctl', 'pbcopy', resolvedUdid], { env: childEnv(), stdio: ['pipe', 'ignore', 'pipe'] })
      let stderr = ''
      proc.stderr?.on('data', (d: Buffer) => { stderr += d.toString() })
      proc.on('error', reject)
      proc.on('close', (code) => {
        if (code === 0) resolve()
        else reject(new Error(`simctl pbcopy exited with code ${code}: ${stderr.trim()}`))
      })
      proc.stdin?.end(content)
    })
  }

  async sendPush(bundleId: string, payload: Record<string, unknown>): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    // simctl push wants the APNS payload as a file on disk.
    const payloadPath = join(tmpdir(), `agentcontroller-push-${Date.now()}.json`)
    await writeFile(payloadPath, JSON.stringify(payload))
    try {
      await execFileAsync('xcrun', ['simctl', 'push', resolvedUdid, bundleId, payloadPath], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
    } finally {
      await unlink(payloadPath).catch(() => {})
    }
  }

  async setLocation(latitude: number, longitude: number): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'location', resolvedUdid, 'set', `${latitude},${longitude}`], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async clearLocation(): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'location', resolvedUdid, 'clear'], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async setPermission(action: 'grant' | 'revoke' | 'reset', service: string, bundleId?: string): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    const args = ['simctl', 'privacy', resolvedUdid, action, service]
    if (bundleId) args.push(bundleId)
    await execFileAsync('xcrun', args, { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async setAppearance(appearance: 'light' | 'dark'): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'ui', resolvedUdid, 'appearance', appearance], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async getAppearance(): Promise<string> {
    const resolvedUdid = await this.getResolvedUdid()
    const { stdout } = await execFileAsync('xcrun', ['simctl', 'ui', resolvedUdid, 'appearance'], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
    return stdout.trim()
  }

  async setContentSize(size: string): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'ui', resolvedUdid, 'content_size', size], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async getContentSize(): Promise<string> {
    const resolvedUdid = await this.getResolvedUdid()
    const { stdout } = await execFileAsync('xcrun', ['simctl', 'ui', resolvedUdid, 'content_size'], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
    return stdout.trim()
  }

  async setStatusBar(overrides: string[]): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'status_bar', resolvedUdid, 'override', ...overrides], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }

  async clearStatusBar(): Promise<void> {
    const resolvedUdid = await this.getResolvedUdid()
    await execFileAsync('xcrun', ['simctl', 'status_bar', resolvedUdid, 'clear'], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  }
}

// Simulator lifecycle is device-level, not client-level: booting can't go
// through an IDBClient instance because the target isn't running yet.
export async function bootSimulator(udid: string): Promise<void> {
  await execFileAsync('xcrun', ['simctl', 'boot', udid], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  // bootstatus -b blocks until the simulator finishes booting.
  await execFileAsync('xcrun', ['simctl', 'bootstatus', udid, '-b'], { env: childEnv(), timeout: 90_000 })
}

export async function shutdownSimulator(udid: string): Promise<void> {
  await execFileAsync('xcrun', ['simctl', 'shutdown', udid], { env: childEnv(), timeout: 30_000 })
}

export async function listAllSimulators(): Promise<{ udid: string; name: string; state: string; runtime: string }[]> {
  const { stdout } = await execFileAsync('xcrun', ['simctl', 'list', 'devices', 'available', '-j'], { env: childEnv(), timeout: SIMCTL_TIMEOUT_MS })
  const data = JSON.parse(stdout) as { devices: Record<string, { udid: string; name: string; state: string }[]> }
  const simulators: { udid: string; name: string; state: string; runtime: string }[] = []
  for (const [runtimeId, devices] of Object.entries(data.devices)) {
    // "com.apple.CoreSimulator.SimRuntime.iOS-18-2" -> "iOS-18-2"
    const runtime = runtimeId.split('.').pop() ?? runtimeId
    for (const device of devices) {
      simulators.push({ udid: device.udid, name: device.name, state: device.state, runtime })
    }
  }
  return simulators
}

export function getIDBClient(udid: string = 'booted'): IDBClient {
  return IDBClient.getInstance(udid)
}

let isCleaningUp = false

async function cleanupAllInstances(): Promise<void> {
  if (isCleaningUp) return
  isCleaningUp = true
  const instances = Array.from((IDBClient as unknown as { instances: Map<string, IDBClient> }).instances.values())
  if (instances.length > 0) {
    log('IDBClient', 'log', `Cleaning up ${instances.length} IDB client instance(s)...`)
    await Promise.all(instances.map(instance => instance.shutdown()))
    log('IDBClient', 'log', 'All IDB client instances cleaned up')
  }
}

process.on('SIGINT', () => {
  cleanupAllInstances().then(() => process.exit(0)).catch(() => process.exit(1))
})

process.on('SIGTERM', () => {
  cleanupAllInstances().then(() => process.exit(0)).catch(() => process.exit(1))
})

export async function shutdownAllIDBClients(): Promise<void> {
  await cleanupAllInstances()
}
