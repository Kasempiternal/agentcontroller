import { spawn, type ChildProcess } from 'child_process'
import { existsSync } from 'fs'
import { fileURLToPath } from 'url'
import * as grpc from '@grpc/grpc-js'
import * as protoLoader from '@grpc/proto-loader'
import { log } from '../logger.js'
import { childEnv } from '../child-env.js'
import { resolveRuntimeFile } from '../paths.js'
import type { ButtonType } from '../types.js'

// Direct gRPC transport to idb_companion — the native daemon the Python idb
// CLI itself talks to. Speaking its protocol directly removes the Python
// interpreter (and its Homebrew-upgrade fragility) from every hot path; the
// Python shell remains only as a fallback owned by IDBClient.

// Relative to both src/idb/ and dist/idb/, the vendored proto lives at
// iOS/proto/idb.proto.
const PROTO_PATH = fileURLToPath(new URL('../../proto/idb.proto', import.meta.url))

function resolveCompanionPath(): string {
  const fromRoots = resolveRuntimeFile('idb-companion', 'bin', 'idb_companion')
  if (fromRoots) return fromRoots
  for (const candidate of [
    '/opt/homebrew/opt/idb-companion/bin/idb_companion',
    '/usr/local/opt/idb-companion/bin/idb_companion',
  ]) {
    if (existsSync(candidate)) return candidate
  }
  return 'idb_companion'
}

// ---- HID event construction, ported from fb-idb idb/common/hid.py ----

type HIDEventMessage = Record<string, unknown>

interface PressAction { touch?: { point: { x: number; y: number } }; button?: { button: string }; key?: { keycode: number } }

function pressWithDuration(action: PressAction, duration?: number): HIDEventMessage[] {
  const events: HIDEventMessage[] = [{ press: { action, direction: 'DOWN' } }]
  if (duration) events.push({ delay: { duration } })
  events.push({ press: { action, direction: 'UP' } })
  return events
}

export function tapEvents(x: number, y: number, duration?: number): HIDEventMessage[] {
  return pressWithDuration({ touch: { point: { x, y } } }, duration)
}

export function buttonEvents(button: Exclude<ButtonType, 'VOLUME_UP' | 'VOLUME_DOWN'>, duration?: number): HIDEventMessage[] {
  return pressWithDuration({ button: { button } }, duration)
}

export function keyEvents(keycode: number, duration?: number): HIDEventMessage[] {
  return pressWithDuration({ key: { keycode } }, duration)
}

export function swipeEvents(fromX: number, fromY: number, toX: number, toY: number, duration?: number, delta?: number): HIDEventMessage[] {
  return [{
    swipe: {
      start: { x: fromX, y: fromY },
      end: { x: toX, y: toY },
      ...(delta !== undefined ? { delta } : {}),
      ...(duration !== undefined ? { duration } : {}),
    },
  }]
}

// HID usage-page keycodes for the ASCII characters idb can type; uppercase
// and symbols wrap the base keycode in a left-shift (225) press.
const KEYCODES: Record<string, number> = {
  a: 4, b: 5, c: 6, d: 7, e: 8, f: 9, g: 10, h: 11, i: 12, j: 13, k: 14, l: 15, m: 16,
  n: 17, o: 18, p: 19, q: 20, r: 21, s: 22, t: 23, u: 24, v: 25, w: 26, x: 27, y: 28, z: 29,
  '1': 30, '2': 31, '3': 32, '4': 33, '5': 34, '6': 35, '7': 36, '8': 37, '9': 38, '0': 39,
  '\n': 40, ';': 51, '=': 46, ',': 54, '-': 45, '.': 55, '/': 56, '`': 53,
  '[': 47, '\\': 49, ']': 48, "'": 52, ' ': 44,
}
const SHIFTED_KEYCODES: Record<string, number> = {
  A: 4, B: 5, C: 6, D: 7, E: 8, F: 9, G: 10, H: 11, I: 12, J: 13, K: 14, L: 15, M: 16,
  N: 17, O: 18, P: 19, Q: 20, R: 21, S: 22, T: 23, U: 24, V: 25, W: 26, X: 27, Y: 28, Z: 29,
  '!': 30, '@': 31, '#': 32, '$': 33, '%': 34, '^': 35, '&': 36, '*': 37, '(': 38, ')': 39,
  '_': 45, '+': 46, '{': 47, '}': 48, ':': 51, '"': 52, '|': 49, '<': 54, '>': 55, '?': 56, '~': 53,
}
const SHIFT_KEYCODE = 225

function keyDown(keycode: number): HIDEventMessage {
  return { press: { action: { key: { keycode } }, direction: 'DOWN' } }
}
function keyUp(keycode: number): HIDEventMessage {
  return { press: { action: { key: { keycode } }, direction: 'UP' } }
}

export function textEvents(text: string): HIDEventMessage[] {
  const events: HIDEventMessage[] = []
  for (const character of text) {
    if (character in KEYCODES) {
      const code = KEYCODES[character]
      events.push(keyDown(code), keyUp(code))
    } else if (character in SHIFTED_KEYCODES) {
      const code = SHIFTED_KEYCODES[character]
      events.push(keyDown(SHIFT_KEYCODE), keyDown(code), keyUp(code), keyUp(SHIFT_KEYCODE))
    } else {
      throw new Error(`No keycode found for ${JSON.stringify(character)}`)
    }
  }
  return events
}

// ---- gRPC client and companion process lifecycle ----

interface CompanionGrpcClient {
  accessibility_info(
    request: Record<string, unknown>,
    options: { deadline: Date },
    callback: (error: Error | null, response?: { json: string }) => void,
  ): void
  hid(
    options: { deadline: Date },
    callback: (error: Error | null) => void,
  ): { write(event: HIDEventMessage): void; end(): void }
  waitForReady(deadline: Date, callback: (error?: Error) => void): void
  close(): void
}

// A badly-attached companion answers describe-all with a single zero-frame
// element (or nothing). A booted simulator always has a describable
// SpringBoard, so that shape means the attach is broken, not the screen empty.
function looksLikeBrokenAttach(parsed: unknown): boolean {
  const elements = Array.isArray(parsed) ? parsed : [parsed]
  if (elements.length === 0) return true
  if (elements.length > 1) return false
  const frame = (elements[0] as { frame?: { width?: number; height?: number } } | undefined)?.frame
  return !frame || ((frame.width ?? 0) === 0 && (frame.height ?? 0) === 0)
}

let serviceCtor: (new (address: string, creds: grpc.ChannelCredentials) => CompanionGrpcClient) | null = null

function loadService(): new (address: string, creds: grpc.ChannelCredentials) => CompanionGrpcClient {
  if (serviceCtor) return serviceCtor
  const definition = protoLoader.loadSync(PROTO_PATH, {
    keepCase: true,
    longs: Number,
    enums: String,
    defaults: false,
  })
  const pkg = grpc.loadPackageDefinition(definition) as unknown as {
    idb: { CompanionService: new (address: string, creds: grpc.ChannelCredentials) => CompanionGrpcClient }
  }
  serviceCtor = pkg.idb.CompanionService
  return serviceCtor
}

export class CompanionClient {
  private static instances: Map<string, CompanionClient> = new Map()

  private udid: string
  private proc: ChildProcess | null = null
  private client: CompanionGrpcClient | null = null
  private starting: Promise<CompanionGrpcClient> | null = null
  private lastStartFailureAt = 0
  private static readonly START_FAILURE_COOLDOWN_MS = 60_000

  private constructor(udid: string) {
    this.udid = udid
  }

  static getInstance(udid: string): CompanionClient {
    if (!CompanionClient.instances.has(udid)) {
      CompanionClient.instances.set(udid, new CompanionClient(udid))
    }
    return CompanionClient.instances.get(udid)!
  }

  private async ensureClient(): Promise<CompanionGrpcClient> {
    if (this.client) return this.client
    // After a failed start, callers must fall back instantly instead of
    // re-paying the startup timeout on every tap for a companion that is
    // missing or broken on this machine.
    if (Date.now() - this.lastStartFailureAt < CompanionClient.START_FAILURE_COOLDOWN_MS) {
      throw new Error('idb_companion recently failed to start; in fallback cooldown')
    }
    if (!this.starting) {
      this.starting = this.startValidated()
        .catch((error) => { this.lastStartFailureAt = Date.now(); throw error })
        .finally(() => { this.starting = null })
    }
    return this.starting
  }

  // The companion's accessibility attach is flaky: an instance that attaches
  // at a bad moment serves a single zero-frame stub element forever, while a
  // fresh attach against the same simulator sees the full tree. Validate the
  // attach with a probe and respawn once before giving up on the transport.
  private async startValidated(): Promise<CompanionGrpcClient> {
    for (let attempt = 1; attempt <= 2; attempt++) {
      const client = await this.start()
      try {
        const parsed = JSON.parse(await this.rawAccessibilityInfo(client, false, undefined, 10_000)) as unknown
        if (!looksLikeBrokenAttach(parsed)) {
          this.client = client
          return client
        }
        log('Companion', 'warn', `[${this.udid}] Attach ${attempt} produced an empty accessibility tree; respawning`)
      } catch (error) {
        log('Companion', 'warn', `[${this.udid}] Attach ${attempt} probe failed: ${error instanceof Error ? error.message : error}`)
      }
      this.teardown(client)
    }
    throw new Error('idb_companion attached with a broken accessibility session twice')
  }

  private teardown(client?: CompanionGrpcClient): void {
    (client ?? this.client)?.close()
    this.client = null
    if (this.proc) {
      this.proc.kill('SIGTERM')
      this.proc = null
    }
  }

  // Spawns idb_companion on an ephemeral port; it announces readiness by
  // printing {"grpc_port":N} on stdout.
  private start(): Promise<CompanionGrpcClient> {
    return new Promise<CompanionGrpcClient>((resolve, reject) => {
      const companionPath = resolveCompanionPath()
      log('Companion', 'log', `Starting ${companionPath} for ${this.udid}`)
      // --only simulator: without it the companion also enumerates and
      // pair-probes every USB-connected iPhone at startup — slow, and it has
      // no business touching physical devices (those go through WDA).
      // --log-level info: the default 'debug' dumps entire AX payloads to
      // stderr on every describe.
      const proc = spawn(companionPath, ['--udid', this.udid, '--grpc-port', '0', '--only', 'simulator', '--log-level', 'info'], {
        env: childEnv(),
        stdio: ['ignore', 'pipe', 'pipe'],
      })
      this.proc = proc
      let settled = false
      let stdoutBuf = ''

      // Consumed but not re-logged: even at info level the companion is
      // chatty, and mirroring it line-by-line would dominate our own log.
      // The tail is kept for startup-failure diagnostics.
      const stderrTail: string[] = []

      const fail = (error: Error) => {
        if (settled) return
        settled = true
        clearTimeout(startupTimer)
        proc.kill('SIGTERM')
        if (this.proc === proc) this.proc = null
        const tail = stderrTail.slice(-3).join(' | ')
        reject(tail ? new Error(`${error.message}; companion stderr: ${tail.slice(0, 300)}`) : error)
      }

      const startupTimer = setTimeout(() => fail(new Error('idb_companion startup timed out')), 25_000)

      proc.stdout?.on('data', (data: Buffer) => {
        stdoutBuf += data.toString()
        let idx: number
        while ((idx = stdoutBuf.indexOf('\n')) >= 0) {
          const line = stdoutBuf.slice(0, idx)
          stdoutBuf = stdoutBuf.slice(idx + 1)
          if (settled || !line.trim()) continue
          try {
            const parsed = JSON.parse(line) as { grpc_port?: number }
            if (typeof parsed.grpc_port === 'number' && parsed.grpc_port > 0) {
              // this.client stays null until startValidated() has probed the
              // attach — a concurrent caller must never see an unvalidated
              // client via the ensureClient fast path.
              this.connectTo(parsed.grpc_port).then((client) => {
                if (settled) { client.close(); return }
                settled = true
                clearTimeout(startupTimer)
                log('Companion', 'log', `[${this.udid}] Ready on port ${parsed.grpc_port}`)
                resolve(client)
              }, fail)
            }
          } catch { /* not the readiness line */ }
        }
      })

      proc.stderr?.on('data', (data: Buffer) => {
        for (const line of data.toString().split('\n')) {
          const trimmed = line.trim()
          if (!trimmed) continue
          stderrTail.push(trimmed)
          if (stderrTail.length > 20) stderrTail.shift()
        }
      })

      proc.on('error', (error) => fail(new Error(`idb_companion failed to start: ${error.message}`)))

      proc.on('exit', (code, signal) => {
        log('Companion', 'log', `[${this.udid}] Exited code=${code} signal=${signal}`)
        if (this.proc === proc) {
          this.proc = null
          this.client?.close()
          this.client = null
        }
        fail(new Error(`idb_companion exited during startup (code=${code})`))
      })
    })
  }

  // The companion binds its gRPC server on IPv6 [::]. It ACCEPTS IPv4-mapped
  // connections but never serves HTTP/2 on them, so "localhost"/127.0.0.1
  // yields a connection that hangs on every call. The IPv6 loopback literal
  // must be tried first; 127.0.0.1 stays as fallback for a v4-only build
  // (where the [::1] attempt fails fast instead of hanging).
  private async connectTo(port: number): Promise<CompanionGrpcClient> {
    const Service = loadService()
    let lastError: Error = new Error('no address attempted')
    for (const address of [`[::1]:${port}`, `127.0.0.1:${port}`]) {
      const client = new Service(address, grpc.credentials.createInsecure())
      try {
        await new Promise<void>((resolve, reject) => {
          client.waitForReady(new Date(Date.now() + 5_000), (error) => error ? reject(error) : resolve())
        })
        return client
      } catch (error) {
        client.close()
        lastError = error instanceof Error ? error : new Error(String(error))
      }
    }
    throw lastError
  }

  private rawAccessibilityInfo(client: CompanionGrpcClient, nested: boolean, point: { x: number; y: number } | undefined, timeoutMs: number): Promise<string> {
    const request: Record<string, unknown> = { format: nested ? 'NESTED' : 'LEGACY' }
    if (point) request.point = point
    return new Promise<string>((resolve, reject) => {
      client.accessibility_info(request, { deadline: new Date(Date.now() + timeoutMs) }, (error, response) => {
        if (error) reject(error)
        else if (!response || typeof response.json !== 'string') reject(new Error('companion returned no accessibility json'))
        else resolve(response.json)
      })
    })
  }

  async accessibilityInfo(nested: boolean, point?: { x: number; y: number }, timeoutMs = 15_000): Promise<unknown> {
    const client = await this.ensureClient()
    return JSON.parse(await this.rawAccessibilityInfo(client, nested, point, timeoutMs))
  }

  async hid(events: HIDEventMessage[], timeoutMs = 15_000): Promise<void> {
    const client = await this.ensureClient()
    await new Promise<void>((resolve, reject) => {
      const call = client.hid({ deadline: new Date(Date.now() + timeoutMs) }, (error) => {
        if (error) reject(error)
        else resolve()
      })
      for (const event of events) call.write(event)
      call.end()
    })
  }

  // Cheap round-trip that forces the process spawn, channel connect, and
  // first AX query so real tool calls find everything hot.
  async ping(): Promise<void> {
    await this.accessibilityInfo(false, { x: 1, y: 1 })
  }

  shutdown(): void {
    this.client?.close()
    this.client = null
    if (this.proc) {
      this.proc.kill('SIGTERM')
      this.proc = null
    }
    CompanionClient.instances.delete(this.udid)
  }

  static shutdownAll(): void {
    for (const instance of Array.from(CompanionClient.instances.values())) {
      instance.shutdown()
    }
  }
}

// Companions are real child processes; without this a killed server leaks
// them attached to the simulator. Signal-triggered cleanup lives with the
// IDBClient handlers; this covers plain exits.
process.on('exit', () => CompanionClient.shutdownAll())
