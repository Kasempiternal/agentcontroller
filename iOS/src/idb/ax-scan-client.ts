import { spawn, type ChildProcess, execFile } from 'child_process'
import { promisify } from 'util'
import { log } from '../logger.js'
import { resolveRuntimeFile } from '../paths.js'
import { childEnv } from '../child-env.js'
import type { ScanRegion, ScanCommand } from '../types.js'

const execFileAsync = promisify(execFile)

function resolveAxScanPath(): string | null {
  return resolveRuntimeFile('bin', 'ax-scan')
}

const DEFAULT_SCREEN_SIZE = { width: 393, height: 852 }

// Fallback only: measuring the live AX tree is authoritative. This map is for
// a simulator whose describe-all is unavailable (idb broken/not installed).
const KNOWN_DEVICE_SIZES: Record<string, { width: number; height: number }> = {
  'iPhone Air': { width: 420, height: 912 },
  'iPhone 17 Pro Max': { width: 440, height: 956 },
  'iPhone 17 Pro': { width: 402, height: 874 },
  'iPhone 17': { width: 402, height: 874 },
  'iPhone 16 Pro Max': { width: 440, height: 956 },
  'iPhone 16 Pro': { width: 402, height: 874 },
  'iPhone 16 Plus': { width: 430, height: 932 },
  'iPhone 16e': { width: 390, height: 844 },
  'iPhone 16': { width: 393, height: 852 },
  'iPhone 15 Pro Max': { width: 430, height: 932 },
  'iPhone 15 Pro': { width: 393, height: 852 },
  'iPhone 15 Plus': { width: 430, height: 932 },
  'iPhone 15': { width: 393, height: 852 },
  'iPhone 14 Pro Max': { width: 430, height: 932 },
  'iPhone 14 Pro': { width: 393, height: 852 },
  'iPhone 14': { width: 390, height: 844 },
  'iPhone SE (3rd generation)': { width: 375, height: 667 },
  'iPad Pro (12.9-inch)': { width: 1024, height: 1366 },
  'iPad Pro (11-inch)': { width: 834, height: 1194 },
  'iPad Air': { width: 820, height: 1180 },
}

// The screen size bounds the scan grid: an undersized guess leaves screen
// edge columns unprobed, so elements there become invisible to scan_ui.
async function resolveDeviceScreenSize(udid: string): Promise<{ width: number; height: number }> {
  // 1) Measure: the root Application/Window element of the AX tree spans the
  // screen, so its frame is the exact size for ANY model, in the simulator's
  // current orientation — no lookup table can go stale on it.
  try {
    const { getIDBClient } = await import('./idb-client.js')
    const raw = await getIDBClient(udid).describeAll(false)
    const elements = (Array.isArray(raw) ? raw : [raw]) as { frame?: { x: number; y: number; width: number; height: number } }[]
    let best: { width: number; height: number } | null = null
    for (const el of elements) {
      const f = el?.frame
      if (f && f.x === 0 && f.y === 0 && f.width >= 100 && f.height >= 100) {
        if (!best || f.width * f.height > best.width * best.height) {
          best = { width: Math.round(f.width), height: Math.round(f.height) }
        }
      }
    }
    if (best) {
      log('AXScan', 'log', `Measured screen size for ${udid}: ${best.width}x${best.height}`)
      return best
    }
  } catch (e) {
    log('AXScan', 'warn', `Could not measure screen size via AX tree for ${udid}: ${e}`)
  }

  // 2) Fall back to the model map keyed off the simulator's device name.
  try {
    const { stdout } = await execFileAsync('xcrun', ['simctl', 'list', 'devices', '-j'], { env: childEnv(), timeout: 10_000 })
    const data = JSON.parse(stdout)
    for (const runtime of Object.values(data.devices) as { udid: string; name: string }[][]) {
      for (const device of runtime) {
        if (device.udid !== udid) continue
        const name = device.name
        if (KNOWN_DEVICE_SIZES[name]) return KNOWN_DEVICE_SIZES[name]
        for (const key of Object.keys(KNOWN_DEVICE_SIZES)) {
          if (name.includes(key) || key.includes(name)) return KNOWN_DEVICE_SIZES[key]
        }
        log('AXScan', 'warn', `Unknown device model "${name}", using default screen size`)
        return DEFAULT_SCREEN_SIZE
      }
    }
  } catch (e) {
    log('AXScan', 'warn', `Failed to resolve device screen size for ${udid}: ${e}`)
  }
  return DEFAULT_SCREEN_SIZE
}

export function regionToCommand(
  region: ScanRegion,
  screenWidth: number,
  screenHeight: number,
  gridStep: number,
): ScanCommand {
  const midX = Math.round(screenWidth / 2)
  const midY = Math.round(screenHeight / 2)
  const pad = Math.round(gridStep / 2)

  switch (region) {
    case 'full':
      return { grid_step: gridStep, x_start: pad, y_start: pad, x_end: screenWidth, y_end: screenHeight }
    case 'top-half':
      return { grid_step: gridStep, x_start: pad, y_start: pad, x_end: screenWidth, y_end: midY }
    case 'bottom-half':
      return { grid_step: gridStep, x_start: pad, y_start: midY, x_end: screenWidth, y_end: screenHeight }
    case 'top-left':
      return { grid_step: gridStep, x_start: pad, y_start: pad, x_end: midX, y_end: midY }
    case 'top-right':
      return { grid_step: gridStep, x_start: midX, y_start: pad, x_end: screenWidth, y_end: midY }
    case 'bottom-left':
      return { grid_step: gridStep, x_start: pad, y_start: midY, x_end: midX, y_end: screenHeight }
    case 'bottom-right':
      return { grid_step: gridStep, x_start: midX, y_start: midY, x_end: screenWidth, y_end: screenHeight }
  }
}

export class AXScanClient {
  private static instances: Map<string, AXScanClient> = new Map()

  private udid: string
  private proc: ChildProcess | null = null
  private ready = false
  private readyPromise: Promise<void> | null = null
  private buffer = ''
  private pendingResolve: ((result: string) => void) | null = null
  private pendingReject: ((err: Error) => void) | null = null
  private pendingTimer: NodeJS.Timeout | null = null

  private screenWidth = 0
  private screenHeight = 0
  private axScanAvailable: boolean

  private constructor(udid: string) {
    this.udid = udid
    this.axScanAvailable = resolveAxScanPath() !== null
  }

  static getInstance(udid: string): AXScanClient {
    if (!AXScanClient.instances.has(udid)) {
      AXScanClient.instances.set(udid, new AXScanClient(udid))
    }
    return AXScanClient.instances.get(udid)!
  }

  private async ensureStarted(): Promise<void> {
    if (this.ready) return
    if (this.readyPromise) return this.readyPromise

    // Resolve screen size
    if (this.screenWidth === 0) {
      const screenSize = await resolveDeviceScreenSize(this.udid)
      this.screenWidth = screenSize.width
      this.screenHeight = screenSize.height
    }

    if (!this.axScanAvailable) {
      // No ax-scan binary — we'll use idb fallback in scan()
      this.ready = true
      return
    }

    const axScanPath = resolveAxScanPath()!

    this.readyPromise = new Promise<void>((resolve, reject) => {
      log('AXScan', 'log', `Starting ax-scan daemon for ${this.udid} (screen: ${this.screenWidth}x${this.screenHeight})`)

      this.proc = spawn(axScanPath, ['--udid', this.udid], {
        stdio: ['pipe', 'pipe', 'pipe'],
      })

      this.proc.stderr?.on('data', (data: Buffer) => {
        const text = data.toString().trim()
        if (text) log('AXScan', 'log', `[${this.udid}] ${text}`)
      })

      this.proc.on('error', (err) => {
        log('AXScan', 'error', `[${this.udid}] Process error: ${err}`)
        this.ready = false
        this.proc = null
        this.readyPromise = null
        this.axScanAvailable = false
        if (this.pendingReject) {
          this.pendingReject(err)
          this.pendingResolve = null
          this.pendingReject = null
        }
      })

      this.proc.on('exit', (code) => {
        log('AXScan', 'log', `[${this.udid}] Daemon exited with code ${code}`)
        this.ready = false
        this.proc = null
        this.readyPromise = null
      })

      this.proc.stdout?.on('data', (data: Buffer) => {
        this.buffer += data.toString()

        if (!this.ready) {
          const readyIdx = this.buffer.indexOf('READY\n')
          if (readyIdx !== -1) {
            this.buffer = this.buffer.slice(readyIdx + 6)
            this.ready = true
            log('AXScan', 'log', `[${this.udid}] Daemon ready`)
            resolve()
            return
          }
        }

        const sentinelIdx = this.buffer.indexOf('\n---\n')
        if (sentinelIdx !== -1 && this.pendingResolve) {
          const response = this.buffer.slice(0, sentinelIdx)
          this.buffer = this.buffer.slice(sentinelIdx + 5)
          const res = this.pendingResolve
          if (this.pendingTimer) clearTimeout(this.pendingTimer)
          this.pendingTimer = null
          this.pendingResolve = null
          this.pendingReject = null
          res(response)
        }
      })

      setTimeout(() => {
        if (!this.ready) {
          reject(new Error('ax-scan daemon startup timed out'))
          this.shutdown()
        }
      }, 10000)
    })

    return this.readyPromise
  }

  private sendCommand(cmd: ScanCommand): Promise<string> {
    return new Promise((resolve, reject) => {
      if (!this.proc?.stdin) {
        reject(new Error('Daemon not running'))
        return
      }
      this.pendingResolve = resolve
      this.pendingReject = reject
      this.proc.stdin.write(JSON.stringify(cmd) + '\n')

      // The timer must be cleared when the response arrives — a stale timer
      // from a completed scan would otherwise reject a later, unrelated one.
      this.pendingTimer = setTimeout(() => {
        if (this.pendingReject) {
          this.pendingReject(new Error('Scan timed out'))
          this.pendingResolve = null
          this.pendingReject = null
          this.pendingTimer = null
        }
      }, 15000)
    })
  }

  async getScreenSize(): Promise<{ width: number; height: number }> {
    await this.ensureStarted()
    return { width: this.screenWidth, height: this.screenHeight }
  }

  async scan(region: ScanRegion, gridStep = 25): Promise<unknown[]> {
    await this.ensureStarted()

    if (!this.axScanAvailable || !this.proc) {
      return this.fallbackScan()
    }

    const cmd = regionToCommand(region, this.screenWidth, this.screenHeight, gridStep)
    const raw = await this.sendCommand(cmd)
    try {
      const parsed = JSON.parse(raw)
      if (parsed.error) throw new Error(parsed.error)
      return Array.isArray(parsed) ? parsed : [parsed]
    } catch (e) {
      throw new Error(`Failed to parse ax-scan response: ${(e as Error).message}`)
    }
  }

  private async fallbackScan(): Promise<unknown[]> {
    log('AXScan', 'log', `[${this.udid}] Using idb describe-all fallback`)
    const { getIDBClient } = await import('./idb-client.js')
    const client = getIDBClient(this.udid)
    const result = await client.describeAll(false)
    return Array.isArray(result) ? result : [result]
  }

  async shutdown(): Promise<void> {
    if (this.proc) {
      this.proc.stdin?.end()
      this.proc.kill('SIGTERM')
      this.proc = null
    }
    this.ready = false
    this.readyPromise = null
    this.buffer = ''
    AXScanClient.instances.delete(this.udid)
  }

  static async shutdownAll(): Promise<void> {
    const instances = Array.from(AXScanClient.instances.values())
    await Promise.all(instances.map(i => i.shutdown()))
  }
}
