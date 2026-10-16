import { exec } from 'child_process'
import { promisify } from 'util'
import { log } from '../logger.js'
import { childEnv } from '../child-env.js'
import { WDAClient } from './wda-client.js'

const execAsync = promisify(exec)

export interface PhysicalDevice {
  udid: string
  name: string
  model: string
  connectionType: 'usb' | 'wifi' | 'both'
  paired: boolean
  developerModeEnabled: boolean
  wdaInstalled: boolean
  wdaRunning: boolean
}

/// The iPhones and iPads devicectl can reach now: on a cable, or on the network. devicectl also
/// lists every device ever paired (a colleague's phone, a Watch) with no transport at all; those
/// used to come back as "usb", so a Mac with two phones plugged in reported eight and every call
/// was ambiguous. Cabled devices first, so "the first physical iPhone" is one on a cable.
export function reachableDevices(json: unknown): PhysicalDevice[] {
  const list = (json as { result?: { devices?: unknown[] } })?.result?.devices ?? []
  const devices: Map<string, PhysicalDevice> = new Map()
  for (const d of list as Record<string, any>[]) {
    const udid = d.hardwareProperties?.udid ?? d.identifier
    if (!udid) continue
    const platform = d.hardwareProperties?.platform
    if (platform !== 'iOS' && platform !== 'iPadOS') continue
    const transport = d.connectionProperties?.transportType
    if (transport !== 'wired' && transport !== 'localNetwork') continue

    devices.set(udid, {
      udid,
      name: d.deviceProperties?.name ?? 'iPhone',
      model: d.hardwareProperties?.marketingName ?? d.hardwareProperties?.productType ?? 'iPhone',
      connectionType: transport === 'wired' ? 'usb' : 'wifi',
      paired: true,
      developerModeEnabled: d.deviceProperties?.developerModeStatus === 'enabled',
      wdaInstalled: false,
      wdaRunning: false,
    })
  }
  return Array.from(devices.values())
    .sort((a, b) => Number(b.connectionType === 'usb') - Number(a.connectionType === 'usb'))
}

export async function listPhysicalDevices(): Promise<PhysicalDevice[]> {
  const devices: Map<string, PhysicalDevice> = new Map()
  let devicectlAnswered = false

  try {
    const { stdout } = await execAsync('xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null', { env: childEnv() })
    const jsonStart = stdout.indexOf('{')
    if (jsonStart < 0) throw new Error('No JSON in devicectl output')
    for (const device of reachableDevices(JSON.parse(stdout.substring(jsonStart)))) {
      devices.set(device.udid, device)
    }
    devicectlAnswered = true
  } catch {
    log('DeviceDiscovery', 'log', 'xcrun devicectl not available, falling back to system_profiler')
  }

  if (!devicectlAnswered) {
    try {
      const { stdout } = await execAsync('system_profiler SPUSBDataType -json 2>/dev/null', { env: childEnv() })
      const json = JSON.parse(stdout)
      const usbItems = json?.SPUSBDataType ?? []

      const findIPhones = (items: Record<string, unknown>[]): void => {
        for (const item of items) {
          const name = item._name as string | undefined
          const serial = item.serial_num as string | undefined
          if (name && serial && (name.includes('iPhone') || name.includes('iPad'))) {
            devices.set(serial, {
              udid: serial,
              name,
              model: name,
              connectionType: 'usb',
              paired: true,
              developerModeEnabled: true,
              wdaInstalled: false,
              wdaRunning: false,
            })
          }
          if (item._items && Array.isArray(item._items)) {
            findIPhones(item._items as Record<string, unknown>[])
          }
        }
      }

      findIPhones(usbItems)
    } catch {
      log('DeviceDiscovery', 'log', 'system_profiler fallback also failed')
    }
  }

  const deviceList = Array.from(devices.values())
  await Promise.all(
    deviceList.map(async (device) => {
      try {
        const client = WDAClient.getInstance(device.udid)
        const running = await client.isReachable()
        device.wdaRunning = running
        device.wdaInstalled = running
      } catch {
        // WDA not reachable
      }
    })
  )

  return deviceList
}

export async function getPhysicalDevice(udid: string): Promise<PhysicalDevice | null> {
  const devices = await listPhysicalDevices()
  return devices.find(d => d.udid === udid) ?? null
}
