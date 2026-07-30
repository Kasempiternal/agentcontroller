import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { z } from 'zod'
import { promises as fs, readFileSync } from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { execFile, spawn, type ChildProcess } from 'node:child_process'
import { resolveBootedUdid, getIDBClient, bootSimulator, shutdownSimulator, listAllSimulators } from './idb/idb-client.js'
import { AXScanClient } from './idb/ax-scan-client.js'
import { getDeviceClient } from './device-client.js'
import { isPhysicalDeviceUdid, type ButtonType, type ScanRegion, type UIElement } from './types.js'
import { WDAClient } from './wda/wda-client.js'
import { wdaScanGrid } from './wda/wda-scan.js'
import { listPhysicalDevices } from './wda/device-discovery.js'
import { applyScanUiFilters, applyDescribeScreenFilters, queryVisibleMatches } from './ui-filters.js'
import { detectExecutionContext } from './execution-context.js'
import { wdaManager } from './wda/wda-manager.js'
import { childEnv } from './child-env.js'
import { log } from './logger.js'
import { emitTapGestureVisualization, emitSwipeGestureVisualization } from './gesture-visualization.js'

const tapParamsSchema = z.object({
  x: z.number().describe('X coordinate to tap'),
  y: z.number().describe('Y coordinate to tap'),
  duration: z.number().optional().describe('Tap duration in seconds'),
})

const swipeParamsSchema = z.object({
  fromX: z.number().describe('Starting X coordinate'),
  fromY: z.number().describe('Starting Y coordinate'),
  toX: z.number().describe('Ending X coordinate'),
  toY: z.number().describe('Ending Y coordinate'),
  duration: z.number().optional().describe('Swipe duration in seconds'),
  delta: z.number().optional().describe('Pixels between touch points'),
})

const buttonParamsSchema = z.object({
  button: z.enum(['HOME', 'LOCK', 'SIDE_BUTTON', 'APPLE_PAY', 'SIRI', 'VOLUME_UP', 'VOLUME_DOWN']).describe('Button to press (VOLUME_* are physical-device only)'),
  duration: z.number().optional().describe('Press duration in seconds'),
})

const inputTextParamsSchema = z.object({
  text: z.string().describe('Text to type'),
})

const keyParamsSchema = z.object({
  key: z.union([z.number(), z.string()]).describe('HID keycode (number) or character (string)'),
  duration: z.number().optional().describe('Key press duration in seconds'),
})

const keySequenceParamsSchema = z.object({
  keySequence: z.array(z.union([z.number(), z.string()])).describe('Sequence of HID keycodes or characters'),
})

const describeAfterSchema = z.object({
  point: z.object({ x: z.number(), y: z.number() }).optional().describe('Describe element at this point after action'),
  all: z.boolean().optional().describe('Describe all elements on screen after action'),
  delay: z.number().optional().describe('Delay in ms before capturing screen state (default: 500)'),
}).optional()

const singleActionSchema = z.object({
  action: z.enum(['tap', 'double-tap', 'swipe', 'button', 'input-text', 'key', 'key-sequence']).describe('Type of action to perform'),
  params: z.record(z.string(), z.unknown()).describe('Action-specific parameters'),
})

const DEFAULT_FRAME = { width: 393, height: 852 }
const referenceFrameCache = new Map<string, Promise<{ width: number; height: number }>>()
const activeRecordings = new Map<string, { proc: ChildProcess; path: string }>()
const BOOTED_UDID_CACHE_TTL_MS = 5_000
let cachedBootedUdid: { value: string; expiresAtMs: number } | null = null

// Width/height from a PNG's IHDR chunk: 8-byte signature, 4-byte chunk
// length, the ASCII type "IHDR", then two big-endian u32 dimensions.
function pngDimensions(header: Buffer): { width: number; height: number } | null {
  if (header.length < 24 || header.readUInt32BE(12) !== 0x49484452) return null
  return { width: header.readUInt32BE(16), height: header.readUInt32BE(20) }
}

async function resolveActionUdid(udid: string): Promise<string> {
  if (udid !== 'booted') return udid

  const now = Date.now()
  if (cachedBootedUdid && cachedBootedUdid.expiresAtMs > now) {
    return cachedBootedUdid.value
  }

  const resolvedUdid = await resolveBootedUdid()
  cachedBootedUdid = {
    value: resolvedUdid,
    expiresAtMs: now + BOOTED_UDID_CACHE_TTL_MS,
  }
  return resolvedUdid
}

async function resolveReferenceFrame(udid: string): Promise<{ width: number; height: number }> {
  const cached = referenceFrameCache.get(udid)
  if (cached) return cached

  const pending = (async () => {
    if (isPhysicalDeviceUdid(udid)) {
      const client = await getDeviceClient(udid) as unknown as WDAClient
      return await client.getWindowSize()
    }

    const axClient = AXScanClient.getInstance(udid)
    return await axClient.getScreenSize()
  })().catch((error) => {
    referenceFrameCache.delete(udid)
    throw error
  })

  referenceFrameCache.set(udid, pending)
  return await pending
}

async function emitVisualizationForAction(params: {
  action: 'tap' | 'swipe'
  udid: string
  actionCommand: string
  actionIndex?: number
  tap?: z.infer<typeof tapParamsSchema>
  swipe?: z.infer<typeof swipeParamsSchema>
}): Promise<void> {
  try {
    const referenceFrame = await resolveReferenceFrame(params.udid)

    if (params.action === 'tap' && params.tap) {
      emitTapGestureVisualization({
        deviceId: params.udid,
        x: params.tap.x,
        y: params.tap.y,
        durationMs: params.tap.duration ? Math.round(params.tap.duration * 1000) : undefined,
        referenceWidth: referenceFrame.width,
        referenceHeight: referenceFrame.height,
        actionCommand: params.actionCommand,
        actionIndex: params.actionIndex,
      })
      return
    }

    if (params.action === 'swipe' && params.swipe) {
      emitSwipeGestureVisualization({
        deviceId: params.udid,
        x: params.swipe.fromX,
        y: params.swipe.fromY,
        x2: params.swipe.toX,
        y2: params.swipe.toY,
        durationMs: Math.round((params.swipe.duration ?? 0.3) * 1000),
        referenceWidth: referenceFrame.width,
        referenceHeight: referenceFrame.height,
        actionCommand: params.actionCommand,
        actionIndex: params.actionIndex,
      })
    }
  } catch (error) {
    log('GestureVisualization', 'warn', `Skipped live overlay event for ${params.action} on ${params.udid}: ${error instanceof Error ? error.message : String(error)}`)
  }
}

const packageJson = JSON.parse(
  readFileSync(new URL('../package.json', import.meta.url), 'utf-8'),
) as { name: string; version: string }

export function createMcpServer(viewerPort: number) {
  const server = new McpServer({
    name: packageJson.name,
    version: packageJson.version,
  })

  server.registerTool(
    'describe_screen',
    {
      description: `Get the full UI element hierarchy of the current screen. Returns ALL element types (buttons, text, images, containers, etc.) that are currently visible on screen.

Filters applied automatically:
- Off-screen elements are excluded
- Generic unlabeled container nodes are excluded

For finding tappable elements specifically, prefer scan_ui instead.`,
      inputSchema: {
        udid: z.string().optional().describe('Device identifier (default: "booted" for current simulator)'),
        nested: z.boolean().optional().describe('Include nested element hierarchy'),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ udid = 'booted', nested = false }) => {
      log('MCP', 'log', `describe_screen udid=${udid} nested=${nested}`)
      try {
        const resolvedUdid = await resolveActionUdid(udid)
        const client = await getDeviceClient(resolvedUdid)
        const [raw, frame] = await Promise.all([
          client.describeAll(nested),
          resolveReferenceFrame(resolvedUdid).catch(() => DEFAULT_FRAME),
        ])

        const rawArray = Array.isArray(raw) ? raw : [raw]
        const filtered = applyDescribeScreenFilters(rawArray as UIElement[], frame.width, frame.height)

        return {
          content: [{ type: 'text' as const, text: JSON.stringify(filtered) }],
        }
      } catch (error) {
        return {
          content: [{ type: 'text' as const, text: `Error describing screen: ${error instanceof Error ? error.message : String(error)}` }],
          isError: true,
        }
      }
    }
  )

  server.registerTool(
    'device_action',
    {
      description: `Execute a single device action on the iPhone.

Actions available:
- tap: Tap at coordinates { x, y, duration? }
- double-tap: Two quick taps at coordinates { x, y }
- swipe: Swipe gesture { fromX, fromY, toX, toY, duration?, delta? }
- button: Press button { button: 'HOME'|'LOCK'|'SIDE_BUTTON'|'APPLE_PAY'|'SIRI'|'VOLUME_UP'|'VOLUME_DOWN', duration? } (VOLUME_* physical devices only)
- input-text: Type text { text }
- key: Press key { key: number (HID keycode) | string (character), duration? }
- key-sequence: Press key sequence { keySequence: (number|string)[] }

Use describe_after to see the screen state after the action.`,
      inputSchema: {
        action: z.enum(['tap', 'double-tap', 'swipe', 'button', 'input-text', 'key', 'key-sequence']).describe('Type of action'),
        params: z.record(z.string(), z.unknown()).describe('Action parameters (depends on action type)'),
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
        describe_after: describeAfterSchema.describe('Optional: describe screen after action'),
      },
      annotations: { readOnlyHint: false, destructiveHint: false },
    },
    async ({ action, params, udid = 'booted', describe_after }) => {
      log('MCP', 'log', `device_action action=${action} udid=${udid}`)
      try {
        const resolvedUdid = await resolveActionUdid(udid)
        const client = await getDeviceClient(resolvedUdid)
        let actionResult = 'Action completed successfully'

        switch (action) {
          case 'tap': {
            const p = tapParamsSchema.parse(params)
            await emitVisualizationForAction({
              action: 'tap',
              udid: resolvedUdid,
              actionCommand: 'device_action',
              actionIndex: 0,
              tap: p,
            })
            await client.tap(p.x, p.y, p.duration)
            actionResult = `Tapped at (${p.x}, ${p.y})`
            break
          }
          case 'double-tap': {
            const p = tapParamsSchema.parse(params)
            await emitVisualizationForAction({
              action: 'tap',
              udid: resolvedUdid,
              actionCommand: 'device_action',
              actionIndex: 0,
              tap: p,
            })
            await client.tap(p.x, p.y)
            await new Promise(resolve => setTimeout(resolve, 80))
            await client.tap(p.x, p.y)
            actionResult = `Double-tapped at (${p.x}, ${p.y})`
            break
          }
          case 'swipe': {
            const p = swipeParamsSchema.parse(params)
            await emitVisualizationForAction({
              action: 'swipe',
              udid: resolvedUdid,
              actionCommand: 'device_action',
              actionIndex: 0,
              swipe: p,
            })
            await client.swipe(p.fromX, p.fromY, p.toX, p.toY, p.duration, p.delta)
            actionResult = `Swiped from (${p.fromX}, ${p.fromY}) to (${p.toX}, ${p.toY})`
            break
          }
          case 'button': {
            const p = buttonParamsSchema.parse(params)
            await client.pressButton(p.button as ButtonType, p.duration)
            actionResult = `Pressed ${p.button} button`
            break
          }
          case 'input-text': {
            const p = inputTextParamsSchema.parse(params)
            await client.inputText(p.text)
            actionResult = `Typed text: "${p.text}"`
            break
          }
          case 'key': {
            const p = keyParamsSchema.parse(params)
            await client.pressKey(p.key, p.duration)
            actionResult = `Pressed key: ${p.key}`
            break
          }
          case 'key-sequence': {
            const p = keySequenceParamsSchema.parse(params)
            await client.pressKeySequence(p.keySequence)
            actionResult = `Pressed key sequence: ${p.keySequence.join(', ')}`
            break
          }
        }

        let descriptionResult: unknown = null
        if (describe_after) {
          await new Promise(resolve => setTimeout(resolve, describe_after.delay ?? 500))
          if (describe_after.all) {
            descriptionResult = await client.describeAll(false)
          } else if (describe_after.point) {
            descriptionResult = await client.describePoint(describe_after.point.x, describe_after.point.y, false)
          }
        }

        const result: { action_result: string; screen_description?: unknown } = { action_result: actionResult }
        if (descriptionResult) result.screen_description = descriptionResult

        return {
          content: [{ type: 'text' as const, text: JSON.stringify(result) }],
        }
      } catch (error) {
        return {
          content: [{ type: 'text' as const, text: `Error executing ${action}: ${error instanceof Error ? error.message : String(error)}` }],
          isError: true,
        }
      }
    }
  )

  server.registerTool(
    'device_actions',
    {
      description: `Execute multiple device actions in sequence on the iPhone.

Each action in the array should have:
- action: 'tap' | 'swipe' | 'button' | 'input-text' | 'key' | 'key-sequence'
- params: Action-specific parameters

Use describe_after to see the screen state after all actions complete.`,
      inputSchema: {
        actions: z.array(singleActionSchema).describe('Array of actions to execute in sequence'),
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
        describe_after: describeAfterSchema.describe('Optional: describe screen after all actions'),
      },
      annotations: { readOnlyHint: false, destructiveHint: false },
    },
    async ({ actions, udid = 'booted', describe_after }) => {
      log('MCP', 'log', `device_actions count=${actions.length} udid=${udid}`)
      try {
        const resolvedUdid = await resolveActionUdid(udid)
        const client = await getDeviceClient(resolvedUdid)
        const results: string[] = []

        for (const [index, { action, params }] of actions.entries()) {
          switch (action) {
            case 'tap': {
              const p = tapParamsSchema.parse(params)
              await emitVisualizationForAction({
                action: 'tap',
                udid: resolvedUdid,
                actionCommand: 'device_actions',
                actionIndex: index,
                tap: p,
              })
              await client.tap(p.x, p.y, p.duration)
              results.push(`Tapped at (${p.x}, ${p.y})`)
              break
            }
            case 'double-tap': {
              const p = tapParamsSchema.parse(params)
              await emitVisualizationForAction({
                action: 'tap',
                udid: resolvedUdid,
                actionCommand: 'device_actions',
                actionIndex: index,
                tap: p,
              })
              await client.tap(p.x, p.y)
              await new Promise(resolve => setTimeout(resolve, 80))
              await client.tap(p.x, p.y)
              results.push(`Double-tapped at (${p.x}, ${p.y})`)
              break
            }
            case 'swipe': {
              const p = swipeParamsSchema.parse(params)
              await emitVisualizationForAction({
                action: 'swipe',
                udid: resolvedUdid,
                actionCommand: 'device_actions',
                actionIndex: index,
                swipe: p,
              })
              await client.swipe(p.fromX, p.fromY, p.toX, p.toY, p.duration, p.delta)
              results.push(`Swiped from (${p.fromX}, ${p.fromY}) to (${p.toX}, ${p.toY})`)
              break
            }
            case 'button': {
              const p = buttonParamsSchema.parse(params)
              await client.pressButton(p.button as ButtonType, p.duration)
              results.push(`Pressed ${p.button} button`)
              break
            }
            case 'input-text': {
              const p = inputTextParamsSchema.parse(params)
              await client.inputText(p.text)
              results.push(`Typed text: "${p.text}"`)
              break
            }
            case 'key': {
              const p = keyParamsSchema.parse(params)
              await client.pressKey(p.key, p.duration)
              results.push(`Pressed key: ${p.key}`)
              break
            }
            case 'key-sequence': {
              const p = keySequenceParamsSchema.parse(params)
              await client.pressKeySequence(p.keySequence)
              results.push(`Pressed key sequence: ${p.keySequence.join(', ')}`)
              break
            }
          }
        }

        let descriptionResult: unknown = null
        if (describe_after) {
          await new Promise(resolve => setTimeout(resolve, describe_after.delay ?? 500))
          if (describe_after.all) {
            descriptionResult = await client.describeAll(false)
          } else if (describe_after.point) {
            descriptionResult = await client.describePoint(describe_after.point.x, describe_after.point.y, false)
          }
        }

        const result: { action_results: string[]; screen_description?: unknown } = { action_results: results }
        if (descriptionResult) result.screen_description = descriptionResult

        return {
          content: [{ type: 'text' as const, text: JSON.stringify(result) }],
        }
      } catch (error) {
        return {
          content: [{ type: 'text' as const, text: `Error executing actions: ${error instanceof Error ? error.message : String(error)}` }],
          isError: true,
        }
      }
    }
  )

  server.registerTool(
    'get_screenshot',
    {
      description: 'Capture a screenshot of the current iPhone screen. Returns the file path to the full-resolution PNG and an inline downscaled preview.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
    },
    async ({ udid = 'booted' }) => {
      log('MCP', 'log', `get_screenshot udid=${udid}`)
      try {
        const timestamp = Date.now()
        const rawFile = path.join(os.tmpdir(), `agentcontroller-ios-screenshot-${timestamp}.png`)
        const resizedFile = path.join(os.tmpdir(), `agentcontroller-ios-screenshot-${timestamp}-sm.jpg`)

        let header: Buffer
        if (isPhysicalDeviceUdid(udid)) {
          const client = await getDeviceClient(udid)
          const pngBuffer = await client.screenshot()
          await fs.writeFile(rawFile, pngBuffer)
          header = pngBuffer.subarray(0, 24)
        } else {
          await new Promise<void>((resolve, reject) => {
            execFile('xcrun', ['simctl', 'io', udid, 'screenshot', '--type=png', rawFile], { env: childEnv(), timeout: 10000 }, (error) => {
              if (error) reject(error)
              else resolve()
            })
          })
          const fh = await fs.open(rawFile, 'r')
          try {
            header = Buffer.alloc(24)
            await fh.read(header, 0, 24, 0)
          } finally {
            await fh.close()
          }
        }

        // PNG dimensions come straight from the IHDR chunk, avoiding a sips
        // process spawn just to ask for the size. The inline preview is a
        // downscaled JPEG: screenshots are photographic enough that JPEG cuts
        // the base64 payload ~4x versus PNG at no practical fidelity cost.
        const dims = pngDimensions(header)
        let imageFile = rawFile
        let mimeType = 'image/png'
        if (dims) {
          await new Promise<void>((resolve, reject) => {
            execFile(
              'sips',
              [
                '--resampleWidth', String(Math.round(dims.width / 3)),
                '--resampleHeight', String(Math.round(dims.height / 3)),
                '-s', 'format', 'jpeg',
                '-s', 'formatOptions', '80',
                rawFile, '--out', resizedFile,
              ],
              { timeout: 5000 },
              (error) => {
                if (error) reject(error)
                else resolve()
              }
            )
          })
          imageFile = resizedFile
          mimeType = 'image/jpeg'
        }

        return {
          content: [
            { type: 'text' as const, text: rawFile },
            { type: 'image' as const, data: (await fs.readFile(imageFile)).toString('base64'), mimeType },
          ],
        }
      } catch (error) {
        return {
          content: [{ type: 'text' as const, text: `Error capturing screenshot: ${error instanceof Error ? error.message : String(error)}` }],
          isError: true,
        }
      }
    }
  )

  server.registerTool(
    'scan_ui',
    {
      description: `Find interactive UI elements (buttons, links, text fields, switches, icons, etc.) on the current screen. Returns only tappable/interactive elements with their coordinates.

Use the "query" parameter to search for a specific element by label (e.g. "Add to Cart", "Settings"). When a query is provided:
- First searches visible interactive elements matching the query
- If not found on-screen, searches off-screen elements and warns you to scroll
- If no interactive match, falls back to all visible interactive elements

Without a query, returns all visible interactive elements on screen.

Region options optimize scan time:
- "top-left" / "top-right" / "bottom-left" / "bottom-right": ~250ms
- "top-half" / "bottom-half": ~500ms
- "full": ~1s (entire screen)

For the complete element tree (all types), use describe_screen instead.`,
      annotations: { readOnlyHint: true },
      inputSchema: {
        region: z.enum(['full', 'top-half', 'bottom-half', 'top-left', 'top-right', 'bottom-left', 'bottom-right'])
          .describe('Screen region to scan'),
        query: z.string().optional().describe('Search for elements matching this text (case-insensitive)'),
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
    },
    async ({ region, query, udid = 'booted' }) => {
      log('MCP', 'log', `scan_ui region=${region} query=${query ?? '(none)'} udid=${udid}`)
      try {
        const resolvedUdid = await resolveActionUdid(udid)

        const scan = isPhysicalDeviceUdid(resolvedUdid)
          ? getDeviceClient(resolvedUdid).then(c => wdaScanGrid(c as unknown as WDAClient, region as ScanRegion))
          : AXScanClient.getInstance(resolvedUdid).scan(region as ScanRegion)
        const [rawElements, frame] = await Promise.all([
          scan,
          resolveReferenceFrame(resolvedUdid).catch(() => DEFAULT_FRAME),
        ])

        const { elements, warning } = applyScanUiFilters(rawElements as UIElement[], frame.width, frame.height, query)

        const content: { type: 'text'; text: string }[] = []
        if (warning) content.push({ type: 'text' as const, text: `Warning: ${warning}` })
        content.push({ type: 'text' as const, text: JSON.stringify(elements) })

        return { content }
      } catch (error) {
        return {
          content: [{ type: 'text' as const, text: `Error scanning UI: ${error instanceof Error ? error.message : String(error)}` }],
          isError: true,
        }
      }
    }
  )

  server.registerTool(
    'list_devices',
    {
      description: 'List all available iPhones and simulators. Simulators include shutdown ones, which can be started with boot_simulator.',
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => {
      log('MCP', 'log', 'list_devices')
      try {
        const [simulators, physicalDevices] = await Promise.all([
          listAllSimulators().catch(() => []),
          listPhysicalDevices(),
        ])

        return {
          content: [{ type: 'text' as const, text: JSON.stringify({ simulators, physicalDevices }) }],
        }
      } catch (error) {
        return {
          content: [{ type: 'text' as const, text: `Error listing devices: ${error instanceof Error ? error.message : String(error)}` }],
          isError: true,
        }
      }
    }
  )

  server.registerTool(
    'get_execution_context',
    {
      description: `Get the current execution context — which iPhone(s) or simulators are available.

Call this first to discover available devices. Returns:
- target: 'simulator' — one simulator booted, use the returned udid
- target: 'device' — one physical device connected, use the returned udid. Inform user about viewer_url for screen viewing.
- target: 'ambiguous' — multiple devices found. Ask the user which one to use.
- target: 'none' — no devices. Tell user to boot a simulator or connect an iPhone.

Pass the returned udid to all subsequent tool calls.`,
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => {
      log('MCP', 'log', 'get_execution_context')
      try {
        const ctx = await detectExecutionContext(viewerPort)

        if (ctx.target === 'simulator') {
          let screenSize: { width: number; height: number } | null = null
          try {
            const axClient = AXScanClient.getInstance(ctx.udid)
            screenSize = await axClient.getScreenSize()
          } catch { /* unavailable */ }

          return {
            content: [{
              type: 'text' as const,
              text: JSON.stringify({
                target: 'simulator',
                udid: ctx.udid,
                name: ctx.name,
                screen_size: screenSize,
              }),
            }],
          }
        }

        if (ctx.target === 'device') {
          let screenSize: { width: number; height: number } | null = null
          try {
            const client = await getDeviceClient(ctx.udid) as unknown as WDAClient
            screenSize = await client.getWindowSize()
          } catch { /* unavailable */ }

          return {
            content: [{
              type: 'text' as const,
              text: JSON.stringify({
                target: 'device',
                udid: ctx.udid,
                device_name: ctx.name,
                model: ctx.model,
                connection_type: ctx.connectionType,
                viewer_url: ctx.viewerUrl,
                screen_size: screenSize,
              }),
            }],
          }
        }

        if (ctx.target === 'ambiguous') {
          return {
            content: [{
              type: 'text' as const,
              text: JSON.stringify({
                target: 'ambiguous',
                message: 'Multiple devices found. Ask the user which device to target.',
                simulators: ctx.simulators,
                physical_devices: ctx.physicalDevices,
              }),
            }],
          }
        }

        return {
          content: [{
            type: 'text' as const,
            text: JSON.stringify({ target: 'none', message: ctx.message }),
          }],
        }
      } catch (error) {
        return {
          content: [{ type: 'text' as const, text: `Error getting execution context: ${error instanceof Error ? error.message : String(error)}` }],
          isError: true,
        }
      }
    }
  )

  server.registerTool(
    'setup_device',
    {
      description: `Build, install, and launch WebDriverAgent on a physical iPhone. This is required before any other tool can interact with a physical device.

Call this when get_execution_context shows a physical device with wdaRunning: false. The process takes 1-3 minutes (building WDA, installing on device, establishing connection).

Prerequisites:
- iPhone connected via USB and trusted
- Developer Mode enabled on iPhone (Settings > Privacy & Security > Developer Mode)
- Apple ID signed into Xcode (Xcode > Settings > Accounts)

After setup completes, use the returned udid for all subsequent tool calls. Also inform the user about the viewer_url where they can see the device screen.`,
      inputSchema: {
        udid: z.string().describe('Physical device UDID from list_devices or get_execution_context'),
      },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true },
    },
    async ({ udid }) => {
      log('MCP', 'log', `setup_device udid=${udid}`)

      // Fast path: WDA already running, just connect
      if (await wdaManager.isWDARunning(udid)) {
        try {
          const tunnelIP = await wdaManager.getTunnelAddress(udid)
          const client = wdaManager.getClient(udid, tunnelIP)
          await client.createSession()
          let screenSize: { width: number; height: number } | null = null
          try { screenSize = await client.getWindowSize() } catch { /* unavailable */ }
          const viewerUrl = `http://localhost:${viewerPort}?udid=${encodeURIComponent(udid)}`
          return {
            content: [{
              type: 'text' as const,
              text: JSON.stringify({ status: 'connected', udid, viewer_url: viewerUrl, screen_size: screenSize })
                + `\n\nIMPORTANT: Tell the user to open this URL to see the device screen: ${viewerUrl}`,
            }],
          }
        } catch (error) {
          return {
            content: [{ type: 'text' as const, text: `Error connecting to WDA: ${error instanceof Error ? error.message : String(error)}` }],
            isError: true,
          }
        }
      }

      // WDA not running — return bash commands for the AI to run manually.
      // Running xcodebuild inside the MCP process causes timeouts; running it
      // via the Bash tool works reliably.
      try {
        const wdaPath = wdaManager.getWdaProjectPathOrNull()
        const teamId = await wdaManager.detectTeamIdPublic()
        const derivedData = wdaManager.getDerivedDataPathPublic()

        const cloneCmd = wdaPath ? null
          : `git clone --depth 1 https://github.com/appium/WebDriverAgent.git ${derivedData}/WebDriverAgent`
        const projectPath = wdaPath ?? `${derivedData}/WebDriverAgent`

        const buildCmd = `xcodebuild build-for-testing -project "${projectPath}/WebDriverAgent.xcodeproj" -scheme WebDriverAgentRunner -destination 'generic/platform=iOS' -derivedDataPath "${derivedData}" -allowProvisioningUpdates DEVELOPMENT_TEAM=${teamId}`

        const launchCmd = `xcodebuild test-without-building -project "${projectPath}/WebDriverAgent.xcodeproj" -scheme WebDriverAgentRunner -destination 'id=${udid}' -derivedDataPath "${derivedData}"`

        const steps = [
          cloneCmd ? `1. Clone WebDriverAgent:\n\`\`\`\n${cloneCmd}\n\`\`\`` : null,
          `${cloneCmd ? '2' : '1'}. Build WDA (watch for a macOS keychain dialog — click "Always Allow"):\n\`\`\`\n${buildCmd}\n\`\`\``,
          `${cloneCmd ? '3' : '2'}. Install and launch WDA — run in background, wait for "ServerURLHere" in output:\n\`\`\`\n${launchCmd}\n\`\`\``,
          `${cloneCmd ? '4' : '3'}. Once "ServerURLHere" appears, call setup_device again — it will connect instantly.`,
        ].filter(Boolean).join('\n\n')

        return {
          content: [{
            type: 'text' as const,
            text: `WebDriverAgent is not running on this device. Run the following commands using your Bash tool, then call setup_device again:\n\n${steps}\n\nKeep the iPhone unlocked throughout.`,
          }],
        }
      } catch (error) {
        return {
          content: [{ type: 'text' as const, text: `Error preparing setup instructions: ${error instanceof Error ? error.message : String(error)}` }],
          isError: true,
        }
      }
    }
  )

  server.registerTool(
    'launch_app',
    {
      description: 'Launch an app on the iPhone by bundle ID.',
      inputSchema: {
        bundleId: z.string().describe('The bundle identifier of the app to launch (e.g. "com.apple.mobilesafari")'),
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
      annotations: { readOnlyHint: false, destructiveHint: false },
    },
    async ({ bundleId, udid = 'booted' }) => {
      log('MCP', 'log', `launch_app bundleId=${bundleId} udid=${udid}`)
      try {
        if (isPhysicalDeviceUdid(udid)) {
          const client = await getDeviceClient(udid) as unknown as WDAClient
          await client.activateApp(bundleId)
        } else {
          await getIDBClient(udid).launch(bundleId)
        }

        return {
          content: [{ type: 'text' as const, text: `Launched ${bundleId}` }],
        }
      } catch (error) {
        return {
          content: [{ type: 'text' as const, text: `Error launching app: ${error instanceof Error ? error.message : String(error)}` }],
          isError: true,
        }
      }
    }
  )

  server.registerTool(
    'list_apps',
    {
      description: 'List installed apps on the iPhone.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
    },
    async ({ udid = 'booted' }) => {
      log('MCP', 'log', `list_apps udid=${udid}`)
      try {
        if (isPhysicalDeviceUdid(udid)) {
          return {
            content: [{ type: 'text' as const, text: 'list_apps is not yet supported for physical devices via WDA.' }],
          }
        }

        const apps = await getIDBClient(udid).listApps()

        const userApps = apps.filter(a => a.type === 'User')
        const systemApps = apps.filter(a => a.type === 'System')

        let text = `User apps (${userApps.length}):\n`
        for (const app of userApps) {
          text += `  ${app.name} — ${app.bundleId}\n`
        }
        text += `\nSystem apps (${systemApps.length}):\n`
        for (const app of systemApps) {
          text += `  ${app.name} — ${app.bundleId}\n`
        }

        return {
          content: [{ type: 'text' as const, text: text.trim() }],
        }
      } catch (error) {
        return {
          content: [{ type: 'text' as const, text: `Error listing apps: ${error instanceof Error ? error.message : String(error)}` }],
          isError: true,
        }
      }
    }
  )

  const err = (text: string) => ({
    content: [{ type: 'text' as const, text }],
    isError: true,
  })
  const ok = (text: string) => ({
    content: [{ type: 'text' as const, text }],
  })

  server.registerTool(
    'open_url',
    {
      description: 'Open a URL on the iPhone — https:// links, deep links, and custom app schemes (e.g. "maps://", "myapp://path").',
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true },
      inputSchema: {
        url: z.string().describe('The URL or deep link to open'),
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
    },
    async ({ url, udid = 'booted' }) => {
      log('MCP', 'log', `open_url url=${url} udid=${udid}`)
      try {
        if (isPhysicalDeviceUdid(udid)) {
          await (await getDeviceClient(udid) as unknown as WDAClient).openUrl(url)
        } else {
          await getIDBClient(udid).openUrl(url)
        }
        return ok(`Opened ${url}`)
      } catch (error) {
        return err(`Error opening URL: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'terminate_app',
    {
      description: 'Terminate a running app on the iPhone by bundle ID.',
      annotations: { readOnlyHint: false, destructiveHint: true },
      inputSchema: {
        bundleId: z.string().describe('The bundle identifier of the app to terminate'),
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
    },
    async ({ bundleId, udid = 'booted' }) => {
      log('MCP', 'log', `terminate_app bundleId=${bundleId} udid=${udid}`)
      try {
        if (isPhysicalDeviceUdid(udid)) {
          await (await getDeviceClient(udid) as unknown as WDAClient).terminateApp(bundleId)
        } else {
          await getIDBClient(udid).terminateApp(bundleId)
        }
        return ok(`Terminated ${bundleId}`)
      } catch (error) {
        return err(`Error terminating app: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'install_app',
    {
      description: 'Install an app on an iOS simulator from a local .app bundle path. Not supported on physical devices.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        appPath: z.string().describe('Absolute path to the .app bundle to install'),
        udid: z.string().optional().describe('Simulator identifier (default: "booted")'),
      },
    },
    async ({ appPath, udid = 'booted' }) => {
      log('MCP', 'log', `install_app appPath=${appPath} udid=${udid}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('install_app is not supported on physical devices; it installs .app bundles on simulators via simctl. Use Xcode or devicectl for physical installs.')
      }
      try {
        await getIDBClient(udid).installApp(appPath)
        return ok(`Installed ${appPath}`)
      } catch (error) {
        return err(`Error installing app: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'uninstall_app',
    {
      description: 'Uninstall an app from an iOS simulator by bundle ID, removing its data. Not supported on physical devices.',
      annotations: { readOnlyHint: false, destructiveHint: true },
      inputSchema: {
        bundleId: z.string().describe('The bundle identifier of the app to uninstall'),
        udid: z.string().optional().describe('Simulator identifier (default: "booted")'),
      },
    },
    async ({ bundleId, udid = 'booted' }) => {
      log('MCP', 'log', `uninstall_app bundleId=${bundleId} udid=${udid}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('uninstall_app is not supported on physical devices; it removes simulator apps via simctl.')
      }
      try {
        await getIDBClient(udid).uninstallApp(bundleId)
        return ok(`Uninstalled ${bundleId}`)
      } catch (error) {
        return err(`Error uninstalling app: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'get_clipboard',
    {
      description: 'Read the iPhone clipboard as plain text. On physical devices this requires WebDriverAgent to be foreground, per iOS pasteboard rules.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
    },
    async ({ udid = 'booted' }) => {
      log('MCP', 'log', `get_clipboard udid=${udid}`)
      try {
        const text = isPhysicalDeviceUdid(udid)
          ? await (await getDeviceClient(udid) as unknown as WDAClient).getPasteboard()
          : await getIDBClient(udid).getClipboard()
        return ok(text)
      } catch (error) {
        return err(`Error reading clipboard: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'set_clipboard',
    {
      description: 'Set the iPhone clipboard to the given text, replacing its current contents.',
      annotations: { readOnlyHint: false, destructiveHint: true },
      inputSchema: {
        text: z.string().describe('Text to place on the clipboard'),
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
    },
    async ({ text, udid = 'booted' }) => {
      log('MCP', 'log', `set_clipboard chars=${text.length} udid=${udid}`)
      try {
        if (isPhysicalDeviceUdid(udid)) {
          await (await getDeviceClient(udid) as unknown as WDAClient).setPasteboard(text)
        } else {
          await getIDBClient(udid).setClipboard(text)
        }
        return ok(`Clipboard set (${text.length} characters)`)
      } catch (error) {
        return err(`Error setting clipboard: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'wait_for_element',
    {
      description: `Wait until an element whose label, title, or value matches the query is visible on screen. Polls the UI until it appears or the timeout elapses.

Use after taps or navigation instead of guessing fixed delays — it returns as soon as the element shows up.`,
      annotations: { readOnlyHint: true },
      inputSchema: {
        query: z.string().describe('Text to match against element labels/titles/values (case-insensitive)'),
        timeoutMs: z.number().optional().describe('How long to keep polling in ms (default: 10000)'),
        intervalMs: z.number().optional().describe('Delay between polls in ms (default: 500)'),
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
    },
    async ({ query, timeoutMs = 10_000, intervalMs = 500, udid = 'booted' }) => {
      log('MCP', 'log', `wait_for_element query=${query} timeoutMs=${timeoutMs} udid=${udid}`)
      try {
        const resolvedUdid = await resolveActionUdid(udid)
        const frame = await resolveReferenceFrame(resolvedUdid).catch(() => DEFAULT_FRAME)
        const deadline = Date.now() + timeoutMs
        const startedAt = Date.now()

        for (;;) {
          const raw = isPhysicalDeviceUdid(resolvedUdid)
            ? await wdaScanGrid(await getDeviceClient(resolvedUdid) as unknown as WDAClient, 'full')
            : await AXScanClient.getInstance(resolvedUdid).scan('full')
          const matches = queryVisibleMatches(raw as UIElement[], frame.width, frame.height, query)
          if (matches.length > 0) {
            return ok(JSON.stringify({ found: true, elapsedMs: Date.now() - startedAt, elements: matches }))
          }
          if (Date.now() + intervalMs > deadline) break
          await new Promise(resolve => setTimeout(resolve, intervalMs))
        }

        return err(`No element matching "${query}" appeared within ${timeoutMs}ms.`)
      } catch (error) {
        return err(`Error waiting for element: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'get_orientation',
    {
      description: 'Get the current screen orientation of a physical iPhone (via WebDriverAgent). Not supported on simulators.',
      annotations: { readOnlyHint: true },
      inputSchema: {
        udid: z.string().describe('Physical device identifier'),
      },
    },
    async ({ udid }) => {
      log('MCP', 'log', `get_orientation udid=${udid}`)
      if (!isPhysicalDeviceUdid(udid)) {
        return err('get_orientation is not supported on simulators; orientation is only exposed through WebDriverAgent on physical devices.')
      }
      try {
        const orientation = await (await getDeviceClient(udid) as unknown as WDAClient).getOrientation()
        return ok(orientation)
      } catch (error) {
        return err(`Error getting orientation: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'set_orientation',
    {
      description: 'Rotate a physical iPhone screen to portrait or landscape (via WebDriverAgent). Not supported on simulators.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        orientation: z.enum(['PORTRAIT', 'LANDSCAPE']).describe('Target orientation'),
        udid: z.string().describe('Physical device identifier'),
      },
    },
    async ({ orientation, udid }) => {
      log('MCP', 'log', `set_orientation orientation=${orientation} udid=${udid}`)
      if (!isPhysicalDeviceUdid(udid)) {
        return err('set_orientation is not supported on simulators; orientation is only exposed through WebDriverAgent on physical devices.')
      }
      try {
        await (await getDeviceClient(udid) as unknown as WDAClient).setOrientation(orientation)
        // Rotation swaps width/height, so the cached reference frame is stale.
        referenceFrameCache.delete(udid)
        return ok(`Orientation set to ${orientation}`)
      } catch (error) {
        return err(`Error setting orientation: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'start_recording',
    {
      description: 'Start recording an iOS simulator screen to an H.264 video file. Stop with stop_recording, which returns the file path. Not supported on physical devices.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        udid: z.string().optional().describe('Simulator identifier (default: "booted")'),
      },
    },
    async ({ udid = 'booted' }) => {
      log('MCP', 'log', `start_recording udid=${udid}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('start_recording is not supported on physical devices; it records simulators via simctl.')
      }
      try {
        const resolvedUdid = await resolveActionUdid(udid)
        if (activeRecordings.has(resolvedUdid)) {
          return err(`A recording is already running for ${resolvedUdid}. Call stop_recording first.`)
        }

        const outPath = path.join(os.tmpdir(), `agentcontroller-ios-recording-${Date.now()}.mp4`)
        const proc = spawn(
          'xcrun',
          ['simctl', 'io', resolvedUdid, 'recordVideo', '--codec', 'h264', '--force', outPath],
          { env: childEnv(), stdio: ['ignore', 'ignore', 'pipe'] },
        )
        let stderr = ''
        proc.stderr?.on('data', (d: Buffer) => { stderr += d.toString() })
        proc.on('exit', () => { activeRecordings.delete(resolvedUdid) })

        // simctl fails fast on a bad udid; give it a beat before reporting success.
        await new Promise(resolve => setTimeout(resolve, 500))
        if (proc.exitCode !== null) {
          return err(`Recording failed to start (exit ${proc.exitCode}): ${stderr.trim()}`)
        }

        activeRecordings.set(resolvedUdid, { proc, path: outPath })
        return ok(JSON.stringify({ recording: true, udid: resolvedUdid, path: outPath }))
      } catch (error) {
        return err(`Error starting recording: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'stop_recording',
    {
      description: 'Stop the active simulator screen recording and return the path of the finished video file.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        udid: z.string().optional().describe('Simulator identifier (default: "booted")'),
      },
    },
    async ({ udid = 'booted' }) => {
      log('MCP', 'log', `stop_recording udid=${udid}`)
      try {
        const resolvedUdid = await resolveActionUdid(udid)
        const recording = activeRecordings.get(resolvedUdid)
        if (!recording) {
          return err(`No active recording for ${resolvedUdid}.`)
        }

        // SIGINT makes simctl finalize the file; wait for the process to exit.
        await new Promise<void>((resolve) => {
          recording.proc.once('exit', () => resolve())
          recording.proc.kill('SIGINT')
        })
        activeRecordings.delete(resolvedUdid)

        return ok(JSON.stringify({ recording: false, path: recording.path }))
      } catch (error) {
        return err(`Error stopping recording: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'tap_element',
    {
      description: `Find an element by text and tap the center of it in one call — scan_ui + tap combined. Matches element labels, titles, and values (case-insensitive).

Prefer this over separate scan_ui and device_action calls when you know what you want to tap.`,
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        query: z.string().describe('Text identifying the element to tap (e.g. "Add to Cart", "Settings")'),
        region: z.enum(['full', 'top-half', 'bottom-half', 'top-left', 'top-right', 'bottom-left', 'bottom-right'])
          .optional().describe('Screen region to search (default: "full")'),
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
    },
    async ({ query, region = 'full', udid = 'booted' }) => {
      log('MCP', 'log', `tap_element query=${query} region=${region} udid=${udid}`)
      try {
        const resolvedUdid = await resolveActionUdid(udid)
        const scan = isPhysicalDeviceUdid(resolvedUdid)
          ? getDeviceClient(resolvedUdid).then(c => wdaScanGrid(c as unknown as WDAClient, region as ScanRegion))
          : AXScanClient.getInstance(resolvedUdid).scan(region as ScanRegion)
        const [rawElements, frame] = await Promise.all([
          scan,
          resolveReferenceFrame(resolvedUdid).catch(() => DEFAULT_FRAME),
        ])

        const matches = queryVisibleMatches(rawElements as UIElement[], frame.width, frame.height, query)
        if (matches.length === 0) {
          return err(`No visible element matching "${query}" found. Use scan_ui to see what is on screen, or scroll if the element may be off-screen.`)
        }

        const target = matches[0]
        const f = target.frame ?? { x: 0, y: 0, width: 0, height: 0 }
        const x = Math.round(f.x + f.width / 2)
        const y = Math.round(f.y + f.height / 2)

        await emitVisualizationForAction({
          action: 'tap',
          udid: resolvedUdid,
          actionCommand: 'tap_element',
          actionIndex: 0,
          tap: { x, y },
        })
        const client = await getDeviceClient(resolvedUdid)
        await client.tap(x, y)

        return ok(JSON.stringify({
          tapped: { x, y },
          element: target,
          other_matches: matches.length - 1,
        }))
      } catch (error) {
        return err(`Error tapping element: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'read_alert',
    {
      description: 'Read the currently displayed system or app alert on a physical iPhone: its text and available buttons. Returns text: null when no alert is showing. Not supported on simulators (use describe_screen there).',
      annotations: { readOnlyHint: true },
      inputSchema: {
        udid: z.string().describe('Physical device identifier'),
      },
    },
    async ({ udid }) => {
      log('MCP', 'log', `read_alert udid=${udid}`)
      if (!isPhysicalDeviceUdid(udid)) {
        return err('read_alert is only available on physical devices via WebDriverAgent; on simulators alerts appear in describe_screen output.')
      }
      try {
        const alert = await (await getDeviceClient(udid) as unknown as WDAClient).getAlert()
        return ok(JSON.stringify(alert))
      } catch (error) {
        return err(`Error reading alert: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'handle_alert',
    {
      description: 'Accept or dismiss the currently displayed alert on a physical iPhone, optionally by tapping a specific button label. Not supported on simulators (tap the alert button directly there).',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        action: z.enum(['accept', 'dismiss']).describe('accept taps the default/confirm button; dismiss taps cancel'),
        buttonLabel: z.string().optional().describe('Tap this specific button label instead of the default'),
        udid: z.string().describe('Physical device identifier'),
      },
    },
    async ({ action, buttonLabel, udid }) => {
      log('MCP', 'log', `handle_alert action=${action} udid=${udid}`)
      if (!isPhysicalDeviceUdid(udid)) {
        return err('handle_alert is only available on physical devices via WebDriverAgent; on simulators tap the alert button directly.')
      }
      try {
        const client = await getDeviceClient(udid) as unknown as WDAClient
        if (action === 'accept') await client.acceptAlert(buttonLabel)
        else await client.dismissAlert(buttonLabel)
        return ok(`Alert ${action}ed${buttonLabel ? ` via "${buttonLabel}"` : ''}`)
      } catch (error) {
        return err(`Error handling alert: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'dismiss_keyboard',
    {
      description: 'Dismiss the on-screen keyboard on a physical iPhone. Not supported on simulators (press the keyboard\'s return/done key instead).',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        udid: z.string().describe('Physical device identifier'),
      },
    },
    async ({ udid }) => {
      log('MCP', 'log', `dismiss_keyboard udid=${udid}`)
      if (!isPhysicalDeviceUdid(udid)) {
        return err('dismiss_keyboard is only available on physical devices via WebDriverAgent.')
      }
      try {
        await (await getDeviceClient(udid) as unknown as WDAClient).dismissKeyboard()
        return ok('Keyboard dismissed')
      } catch (error) {
        return err(`Error dismissing keyboard: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'lock_screen',
    {
      description: 'Lock the screen of a physical iPhone (like pressing the side button). Not supported on simulators.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        udid: z.string().describe('Physical device identifier'),
      },
    },
    async ({ udid }) => {
      log('MCP', 'log', `lock_screen udid=${udid}`)
      if (!isPhysicalDeviceUdid(udid)) {
        return err('lock_screen is only available on physical devices via WebDriverAgent.')
      }
      try {
        await (await getDeviceClient(udid) as unknown as WDAClient).lock()
        return ok('Screen locked')
      } catch (error) {
        return err(`Error locking screen: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'unlock_screen',
    {
      description: 'Unlock the screen of a physical iPhone. Only works when the device has no passcode, or is passcode-unlocked but showing the lock screen.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        udid: z.string().describe('Physical device identifier'),
      },
    },
    async ({ udid }) => {
      log('MCP', 'log', `unlock_screen udid=${udid}`)
      if (!isPhysicalDeviceUdid(udid)) {
        return err('unlock_screen is only available on physical devices via WebDriverAgent.')
      }
      try {
        await (await getDeviceClient(udid) as unknown as WDAClient).unlock()
        return ok('Screen unlocked')
      } catch (error) {
        return err(`Error unlocking screen: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'get_device_info',
    {
      description: `Get device details. Physical iPhones report model, OS, battery level and charging state, thermal state, lock state, and the currently active app. Simulators report name, runtime, state, and light/dark appearance.`,
      annotations: { readOnlyHint: true },
      inputSchema: {
        udid: z.string().optional().describe('Device identifier (default: "booted")'),
      },
    },
    async ({ udid = 'booted' }) => {
      log('MCP', 'log', `get_device_info udid=${udid}`)
      try {
        if (isPhysicalDeviceUdid(udid)) {
          const client = await getDeviceClient(udid) as unknown as WDAClient
          const [device, battery, locked, activeApp] = await Promise.all([
            client.getDeviceInfo().catch(() => null),
            client.getBatteryInfo().catch(() => null),
            client.isLocked().catch(() => null),
            client.getActiveAppInfo().catch(() => null),
          ])
          const batteryStates = ['unknown', 'unplugged', 'charging', 'full']
          return ok(JSON.stringify({
            target: 'device',
            udid,
            device,
            battery: battery ? { level: battery.level, state: batteryStates[battery.state] ?? battery.state } : null,
            locked,
            active_app: activeApp,
          }))
        }

        const resolvedUdid = await resolveActionUdid(udid)
        const [simulators, appearance, contentSize] = await Promise.all([
          listAllSimulators(),
          getIDBClient(resolvedUdid).getAppearance().catch(() => null),
          getIDBClient(resolvedUdid).getContentSize().catch(() => null),
        ])
        const sim = simulators.find(s => s.udid === resolvedUdid)
        if (!sim) return err(`Simulator ${resolvedUdid} not found.`)
        return ok(JSON.stringify({ target: 'simulator', ...sim, appearance, content_size: contentSize }))
      } catch (error) {
        return err(`Error getting device info: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'send_push',
    {
      description: `Send a simulated push notification to an app on an iOS simulator. The payload is a full APNS dictionary, e.g. {"aps":{"alert":{"title":"Hi","body":"There"},"badge":1,"sound":"default"}}. Not supported on physical devices.`,
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        bundleId: z.string().describe('Bundle ID of the app to receive the notification'),
        payload: z.record(z.string(), z.unknown()).describe('APNS payload object; must contain an "aps" key'),
        udid: z.string().optional().describe('Simulator identifier (default: "booted")'),
      },
    },
    async ({ bundleId, payload, udid = 'booted' }) => {
      log('MCP', 'log', `send_push bundleId=${bundleId} udid=${udid}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('send_push is not supported on physical devices; simctl can only inject notifications into simulators.')
      }
      if (!('aps' in payload)) {
        return err('The payload must contain an "aps" key, e.g. {"aps":{"alert":"Hello"}}.')
      }
      try {
        await getIDBClient(udid).sendPush(bundleId, payload)
        return ok(`Push notification delivered to ${bundleId}`)
      } catch (error) {
        return err(`Error sending push: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'set_location',
    {
      description: 'Set (or clear) the simulated GPS location of an iOS simulator. Not supported on physical devices.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        latitude: z.number().optional().describe('Latitude in decimal degrees'),
        longitude: z.number().optional().describe('Longitude in decimal degrees'),
        clear: z.boolean().optional().describe('Clear the simulated location instead of setting one'),
        udid: z.string().optional().describe('Simulator identifier (default: "booted")'),
      },
    },
    async ({ latitude, longitude, clear, udid = 'booted' }) => {
      log('MCP', 'log', `set_location lat=${latitude} lon=${longitude} clear=${clear} udid=${udid}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('set_location is not supported on physical devices; simctl can only simulate location on simulators.')
      }
      try {
        if (clear) {
          await getIDBClient(udid).clearLocation()
          return ok('Simulated location cleared')
        }
        if (latitude === undefined || longitude === undefined) {
          return err('Provide latitude and longitude, or clear: true.')
        }
        await getIDBClient(udid).setLocation(latitude, longitude)
        return ok(`Location set to (${latitude}, ${longitude})`)
      } catch (error) {
        return err(`Error setting location: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'set_permission',
    {
      description: `Grant, revoke, or reset a privacy permission for an app on an iOS simulator — bypasses the permission prompt entirely. Not supported on physical devices.

Services: all, calendar, contacts, contacts-limited, location, location-always, media-library, microphone, motion, photos, photos-add, reminders, siri.`,
      annotations: { readOnlyHint: false, destructiveHint: true },
      inputSchema: {
        action: z.enum(['grant', 'revoke', 'reset']).describe('What to do with the permission'),
        service: z.enum(['all', 'calendar', 'contacts', 'contacts-limited', 'location', 'location-always', 'media-library', 'microphone', 'motion', 'photos', 'photos-add', 'reminders', 'siri'])
          .describe('The privacy service to modify'),
        bundleId: z.string().optional().describe('App bundle ID (omit to affect all apps, only valid with reset)'),
        udid: z.string().optional().describe('Simulator identifier (default: "booted")'),
      },
    },
    async ({ action, service, bundleId, udid = 'booted' }) => {
      log('MCP', 'log', `set_permission action=${action} service=${service} bundleId=${bundleId} udid=${udid}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('set_permission is not supported on physical devices; simctl privacy only works on simulators.')
      }
      try {
        await getIDBClient(udid).setPermission(action, service, bundleId)
        return ok(`Permission ${service}: ${action}${bundleId ? ` for ${bundleId}` : ''}`)
      } catch (error) {
        return err(`Error setting permission: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'set_appearance',
    {
      description: 'Switch an iOS simulator between light and dark appearance. Not supported on physical devices.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        appearance: z.enum(['light', 'dark']).describe('Target appearance'),
        udid: z.string().optional().describe('Simulator identifier (default: "booted")'),
      },
    },
    async ({ appearance, udid = 'booted' }) => {
      log('MCP', 'log', `set_appearance appearance=${appearance} udid=${udid}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('set_appearance is not supported on physical devices; simctl ui only works on simulators.')
      }
      try {
        await getIDBClient(udid).setAppearance(appearance)
        return ok(`Appearance set to ${appearance}`)
      } catch (error) {
        return err(`Error setting appearance: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'set_status_bar',
    {
      description: 'Override the status bar of an iOS simulator (time, battery, network) — useful for clean screenshots. Pass clear: true to remove all overrides. Not supported on physical devices.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        time: z.string().optional().describe('Time string to display, e.g. "9:41"'),
        batteryLevel: z.number().optional().describe('Battery percentage 0-100'),
        batteryState: z.enum(['charging', 'charged', 'discharging']).optional().describe('Battery state'),
        operatorName: z.string().optional().describe('Carrier name to display'),
        dataNetwork: z.enum(['wifi', '3g', '4g', 'lte', 'lte-a', 'lte+', '5g', '5g+', '5g-uwb', '5g-uc']).optional().describe('Data network indicator'),
        wifiBars: z.number().optional().describe('Wi-Fi signal bars 0-3'),
        cellularBars: z.number().optional().describe('Cellular signal bars 0-4'),
        clear: z.boolean().optional().describe('Remove all status bar overrides'),
        udid: z.string().optional().describe('Simulator identifier (default: "booted")'),
      },
    },
    async ({ time, batteryLevel, batteryState, operatorName, dataNetwork, wifiBars, cellularBars, clear, udid = 'booted' }) => {
      log('MCP', 'log', `set_status_bar udid=${udid} clear=${clear}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('set_status_bar is not supported on physical devices; simctl status_bar only works on simulators.')
      }
      try {
        if (clear) {
          await getIDBClient(udid).clearStatusBar()
          return ok('Status bar overrides cleared')
        }
        const overrides: string[] = []
        if (time !== undefined) overrides.push('--time', time)
        if (batteryLevel !== undefined) overrides.push('--batteryLevel', String(batteryLevel))
        if (batteryState !== undefined) overrides.push('--batteryState', batteryState)
        if (operatorName !== undefined) overrides.push('--operatorName', operatorName)
        if (dataNetwork !== undefined) overrides.push('--dataNetwork', dataNetwork)
        if (wifiBars !== undefined) overrides.push('--wifiMode', 'active', '--wifiBars', String(wifiBars))
        if (cellularBars !== undefined) overrides.push('--cellularMode', 'active', '--cellularBars', String(cellularBars))
        if (overrides.length === 0) {
          return err('Provide at least one override (time, batteryLevel, ...) or clear: true.')
        }
        await getIDBClient(udid).setStatusBar(overrides)
        return ok('Status bar overridden')
      } catch (error) {
        return err(`Error setting status bar: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'set_content_size',
    {
      description: 'Set the Dynamic Type content size of an iOS simulator — essential for accessibility/text-scaling QA. An oversized setting also shrinks how much fits on screen, which affects what scan_ui can find. Not supported on physical devices.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        size: z.enum([
          'extra-small', 'small', 'medium', 'large', 'extra-large', 'extra-extra-large', 'extra-extra-extra-large',
          'accessibility-medium', 'accessibility-large', 'accessibility-extra-large', 'accessibility-extra-extra-large', 'accessibility-extra-extra-extra-large',
        ]).describe('Dynamic Type size ("large" is the iOS default)'),
        udid: z.string().optional().describe('Simulator identifier (default: "booted")'),
      },
    },
    async ({ size, udid = 'booted' }) => {
      log('MCP', 'log', `set_content_size size=${size} udid=${udid}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('set_content_size is not supported on physical devices; simctl ui only works on simulators.')
      }
      try {
        await getIDBClient(udid).setContentSize(size)
        return ok(`Content size set to ${size}`)
      } catch (error) {
        return err(`Error setting content size: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'boot_simulator',
    {
      description: 'Boot a shutdown iOS simulator by UDID and wait until it finishes booting. Get UDIDs from list_devices. The simulator runs headless; all tools work against it without the Simulator app being open.',
      annotations: { readOnlyHint: false, destructiveHint: false },
      inputSchema: {
        udid: z.string().describe('Simulator UDID to boot'),
      },
    },
    async ({ udid }) => {
      log('MCP', 'log', `boot_simulator udid=${udid}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('boot_simulator only boots simulators; physical devices boot themselves.')
      }
      try {
        await bootSimulator(udid)
        return ok(`Simulator ${udid} booted`)
      } catch (error) {
        return err(`Error booting simulator: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  server.registerTool(
    'shutdown_simulator',
    {
      description: 'Shut down a running iOS simulator by UDID, closing all its apps.',
      annotations: { readOnlyHint: false, destructiveHint: true },
      inputSchema: {
        udid: z.string().describe('Simulator UDID to shut down'),
      },
    },
    async ({ udid }) => {
      log('MCP', 'log', `shutdown_simulator udid=${udid}`)
      if (isPhysicalDeviceUdid(udid)) {
        return err('shutdown_simulator only shuts down simulators.')
      }
      try {
        await shutdownSimulator(udid)
        // The booted-udid cache may now point at a dead simulator.
        cachedBootedUdid = null
        referenceFrameCache.delete(udid)
        return ok(`Simulator ${udid} shut down`)
      } catch (error) {
        return err(`Error shutting down simulator: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
  )

  return server
}
