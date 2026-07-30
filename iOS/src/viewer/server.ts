import express from 'express'
import { createServer, type Server } from 'node:http'
import { WebSocketServer, WebSocket } from 'ws'
import { log } from '../logger.js'
import { WDAClient } from '../wda/wda-client.js'
import { getDeviceClient } from '../device-client.js'

const VIEWER_HTML = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AgentController iOS viewer</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { background: #1a1a1a; display: flex; justify-content: center; align-items: center; height: 100vh; font-family: system-ui; }
  .device-frame {
    background: #2C2B2C;
    border-radius: 44px;
    padding: 16px;
    box-shadow: 0 20px 60px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.05);
  }
  .screen-container {
    background: #000;
    border-radius: 32px;
    overflow: hidden;
    position: relative;
  }
  canvas {
    display: block;
    width: 100%;
    height: 100%;
  }
  .status {
    position: fixed;
    bottom: 16px;
    left: 50%;
    transform: translateX(-50%);
    color: #666;
    font-size: 12px;
  }
  .no-device {
    color: #888;
    text-align: center;
    padding: 40px;
    font-size: 14px;
  }
</style>
</head>
<body>
<div id="root">
  <div class="no-device" id="no-device">Connecting to device...</div>
</div>
<div class="status" id="status"></div>
<script>
  const params = new URLSearchParams(location.search);
  const udid = params.get('udid');
  if (!udid) {
    document.getElementById('no-device').textContent = 'No device UDID specified. Use ?udid=DEVICE_UDID';
  } else {
    const root = document.getElementById('root');
    root.innerHTML = '';
    const frame = document.createElement('div');
    frame.className = 'device-frame';
    const container = document.createElement('div');
    container.className = 'screen-container';
    const canvas = document.createElement('canvas');
    container.appendChild(canvas);
    frame.appendChild(container);
    root.appendChild(frame);

    const ctx = canvas.getContext('2d');
    const status = document.getElementById('status');
    let frameCount = 0;
    let lastFpsTime = Date.now();

    const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(wsProto + '//' + location.host + '/stream/' + encodeURIComponent(udid));
    ws.binaryType = 'arraybuffer';

    ws.onopen = () => { status.textContent = 'Connected'; };
    ws.onclose = () => { status.textContent = 'Disconnected'; };
    ws.onerror = () => { status.textContent = 'Connection error'; };

    ws.onmessage = (event) => {
      const blob = new Blob([event.data], { type: 'image/png' });
      const url = URL.createObjectURL(blob);
      const img = new Image();
      img.onload = () => {
        if (canvas.width !== img.width || canvas.height !== img.height) {
          canvas.width = img.width;
          canvas.height = img.height;
          const aspect = img.width / img.height;
          const maxH = window.innerHeight - 100;
          const h = Math.min(maxH, 800);
          container.style.width = Math.round(h * aspect) + 'px';
          container.style.height = h + 'px';
        }
        ctx.drawImage(img, 0, 0);
        URL.revokeObjectURL(url);
        frameCount++;
        const now = Date.now();
        if (now - lastFpsTime >= 1000) {
          status.textContent = frameCount + ' fps';
          frameCount = 0;
          lastFpsTime = now;
        }
      };
      img.src = url;
    };
  }
</script>
</body>
</html>`

interface DeviceStreamRelay {
  clients: Set<WebSocket>
  intervalId: ReturnType<typeof setInterval>
}

const activeRelays = new Map<string, DeviceStreamRelay>()
const MAX_CONSECUTIVE_FAILURES = 10

function startRelay(udid: string, client: WDAClient, ws: WebSocket): void {
  const existing = activeRelays.get(udid)
  if (existing) {
    existing.clients.add(ws)
    log('ViewerRelay', 'log', `Client joined relay for ${udid} (${existing.clients.size} clients)`)
    return
  }

  const clients = new Set<WebSocket>([ws])
  let pending = false
  let consecutiveFailures = 0

  const intervalId = setInterval(async () => {
    if (pending || clients.size === 0) return
    pending = true
    try {
      const pngBuffer = await client.screenshot()
      consecutiveFailures = 0
      for (const c of clients) {
        if (c.readyState === WebSocket.OPEN) c.send(pngBuffer)
      }
    } catch (e) {
      consecutiveFailures++
      if (consecutiveFailures <= 3 || consecutiveFailures === MAX_CONSECUTIVE_FAILURES) {
        log('ViewerRelay', 'warn', `Screenshot poll failed for ${udid} (${consecutiveFailures}/${MAX_CONSECUTIVE_FAILURES}): ${e}`)
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        log('ViewerRelay', 'warn', `Stopping relay for ${udid} after ${MAX_CONSECUTIVE_FAILURES} consecutive failures`)
        for (const c of clients) c.close(1011, 'WDA session lost')
        clearInterval(intervalId)
        activeRelays.delete(udid)
      }
    } finally {
      pending = false
    }
  }, 50)

  activeRelays.set(udid, { clients, intervalId })
  log('ViewerRelay', 'log', `Started relay for ${udid}`)
}

function removeClientFromRelay(udid: string, ws: WebSocket): void {
  const relay = activeRelays.get(udid)
  if (!relay) return
  relay.clients.delete(ws)
  if (relay.clients.size === 0) {
    clearInterval(relay.intervalId)
    activeRelays.delete(udid)
    log('ViewerRelay', 'log', `Stopped relay for ${udid} (no clients)`)
  }
}

export function createViewerServer(): { server: Server; start: (port: number) => Promise<number> } {
  const app = express()

  app.get('/', (_req, res) => {
    res.type('html').send(VIEWER_HTML)
  })

  app.get('/health', (_req, res) => {
    res.json({ ok: true })
  })

  const httpServer = createServer(app)
  const wss = new WebSocketServer({ noServer: true })

  httpServer.on('upgrade', (req, socket, head) => {
    const rawUrl = req.url ?? ''
    let pathname = ''
    try {
      pathname = new URL(rawUrl, 'http://localhost').pathname
    } catch {
      return
    }

    const match = pathname.match(/^\/stream\/([^/]+)$/)
    if (!match) return

    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit('connection', ws, req, match[1])
    })
  })

  wss.on('connection', (ws: WebSocket, _req: unknown, udid: string) => {
    const decodedUdid = decodeURIComponent(udid)
    log('ViewerRelay', 'log', `WS connected for device ${decodedUdid}`)

    void (async () => {
      try {
        const client = await getDeviceClient(decodedUdid) as WDAClient
        startRelay(decodedUdid, client, ws)

        ws.on('close', () => removeClientFromRelay(decodedUdid, ws))
        ws.on('error', () => removeClientFromRelay(decodedUdid, ws))
      } catch (e) {
        log('ViewerRelay', 'error', `Failed to start relay for ${decodedUdid}: ${e}`)
        ws.close(1011, 'Failed to connect to device')
      }
    })()
  })

  const start = (port: number): Promise<number> => {
    return new Promise((resolve, reject) => {
      const tryPort = (p: number) => {
        httpServer.once('error', (err: NodeJS.ErrnoException) => {
          if (err.code === 'EADDRINUSE' && p < port + 50) {
            tryPort(p + 1)
          } else {
            reject(err)
          }
        })
        httpServer.listen(p, () => {
          const addr = httpServer.address()
          const boundPort = typeof addr === 'object' && addr ? addr.port : p
          log('Viewer', 'log', `Viewer server listening on http://localhost:${boundPort}`)
          resolve(boundPort)
        })
      }
      tryPort(port)
    })
  }

  return { server: httpServer, start }
}
