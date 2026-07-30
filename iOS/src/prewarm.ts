import { resolveBootedUdid, getIDBClient } from './idb/idb-client.js'
import { AXScanClient } from './idb/ax-scan-client.js'
import { log } from './logger.js'

// Fire-and-forget warmup of the simulator transports. Everything here is a
// singleton keyed by udid, so a tool call arriving mid-warmup joins the same
// in-flight work instead of duplicating it. Failures are logged and swallowed:
// no booted simulator just means there is nothing to warm.
export function prewarmSimulator(udid?: string): void {
  void (async () => {
    try {
      const resolved = udid ?? await resolveBootedUdid()
      const started = Date.now()
      await Promise.allSettled([
        getIDBClient(resolved).warmup(),
        AXScanClient.getInstance(resolved).getScreenSize(),
      ])
      log('Server', 'log', `Prewarmed simulator transports for ${resolved} in ${Date.now() - started}ms`)
    } catch (e) {
      log('Server', 'log', `Prewarm skipped: ${e instanceof Error ? e.message : e}`)
    }
  })()
}
