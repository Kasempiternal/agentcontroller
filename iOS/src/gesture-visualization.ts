import os from 'node:os'
import path from 'node:path'
import { createRequire } from 'node:module'
import { log } from './logger.js'

interface UnixDgramModule {
  createSocket(type: 'unix_dgram'): {
    on(event: 'error', listener: (error: Error) => void): void
    send(buf: Buffer, offset: number, length: number, path: string, callback?: (error?: Error | null) => void): void
    close(): void
  }
}

// unix-dgram is a native optional dependency; without it the live gesture
// overlay is silently unavailable, which must not prevent the server starting.
const require = createRequire(import.meta.url)
let unixDgram: UnixDgramModule | null = null
try {
  unixDgram = require('unix-dgram') as UnixDgramModule
} catch {
  log('GestureVisualization', 'warn', 'unix-dgram unavailable; gesture overlay events disabled')
}

// The live gesture overlay is drawn by an external viewer process that is not
// part of this repository, so the socket name is that viewer's contract rather
// than ours — renaming either of these stops the overlay receiving events
// without any error surfacing. Our own env var takes precedence for viewers
// that follow the AgentController convention.
const LEGACY_SOCKET_ENV = 'BLITZ_GESTURE_EVENTS_SOCKET'
const LEGACY_SOCKET_PATH = ['.blitz', 'gesture-events.sock']

const GESTURE_SOCKET_PATH = process.env.AGENTCONTROLLER_GESTURE_EVENTS_SOCKET
  ?? process.env[LEGACY_SOCKET_ENV]
  ?? path.join(os.homedir(), ...LEGACY_SOCKET_PATH)
const GESTURE_SOURCE = {
  client: 'agentcontroller-ios',
  sessionId: `pid-${process.pid}`,
}

let socket: ReturnType<UnixDgramModule['createSocket']> | null = null
let socketErrorLogged = false

type GestureKind = 'tap' | 'swipe'

interface GestureVisualizationEvent {
  v: 1
  id: string
  tsMs: number
  source: typeof GESTURE_SOURCE
  target: {
    platform: 'ios'
    deviceId: string
  }
  kind: GestureKind
  referenceWidth: number
  referenceHeight: number
  durationMs?: number
  actionCommand?: string
  actionIndex?: number
  x?: number
  y?: number
  x2?: number
  y2?: number
}

function getSocket() {
  if (socket) return socket
  if (!unixDgram) return null
  socket = unixDgram.createSocket('unix_dgram')
  socket.on('error', (error) => {
    if (!socketErrorLogged) {
      socketErrorLogged = true
      log('GestureVisualization', 'warn', `Socket error: ${error.message}`)
    }
  })
  return socket
}

function nextEventId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
}

export function emitTapGestureVisualization(params: {
  deviceId: string
  x: number
  y: number
  referenceWidth: number
  referenceHeight: number
  durationMs?: number
  actionCommand?: string
  actionIndex?: number
}): void {
  emitGestureVisualization({
    kind: 'tap',
    deviceId: params.deviceId,
    x: params.x,
    y: params.y,
    referenceWidth: params.referenceWidth,
    referenceHeight: params.referenceHeight,
    durationMs: params.durationMs,
    actionCommand: params.actionCommand,
    actionIndex: params.actionIndex,
  })
}

export function emitSwipeGestureVisualization(params: {
  deviceId: string
  x: number
  y: number
  x2: number
  y2: number
  referenceWidth: number
  referenceHeight: number
  durationMs?: number
  actionCommand?: string
  actionIndex?: number
}): void {
  emitGestureVisualization({
    kind: 'swipe',
    deviceId: params.deviceId,
    x: params.x,
    y: params.y,
    x2: params.x2,
    y2: params.y2,
    referenceWidth: params.referenceWidth,
    referenceHeight: params.referenceHeight,
    durationMs: params.durationMs,
    actionCommand: params.actionCommand,
    actionIndex: params.actionIndex,
  })
}

function emitGestureVisualization(params: {
  kind: GestureKind
  deviceId: string
  x: number
  y: number
  x2?: number
  y2?: number
  referenceWidth: number
  referenceHeight: number
  durationMs?: number
  actionCommand?: string
  actionIndex?: number
}): void {
  const event: GestureVisualizationEvent = {
    v: 1,
    id: nextEventId(),
    tsMs: Date.now(),
    source: GESTURE_SOURCE,
    target: {
      platform: 'ios',
      deviceId: params.deviceId,
    },
    kind: params.kind,
    x: params.x,
    y: params.y,
    x2: params.x2,
    y2: params.y2,
    referenceWidth: params.referenceWidth,
    referenceHeight: params.referenceHeight,
    durationMs: params.durationMs,
    actionCommand: params.actionCommand,
    actionIndex: params.actionIndex,
  }

  try {
    const sock = getSocket()
    if (!sock) return
    const payload = Buffer.from(JSON.stringify(event))
    sock.send(payload, 0, payload.length, GESTURE_SOCKET_PATH, (error?: Error | null) => {
      if (error && !socketErrorLogged) {
        socketErrorLogged = true
        log('GestureVisualization', 'warn', `Failed to send event: ${error.message}`)
      }
    })
  } catch (error) {
    if (!socketErrorLogged) {
      socketErrorLogged = true
      log('GestureVisualization', 'warn', `Failed to encode/send event: ${error instanceof Error ? error.message : String(error)}`)
    }
  }
}

process.once('exit', () => {
  try {
    socket?.close()
  } catch {
    // Ignore shutdown errors.
  }
})
