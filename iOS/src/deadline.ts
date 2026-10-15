/**
 * A hard ceiling for device calls that can stall (a locked phone, a wedged WebDriverAgent,
 * a busy idb companion). Without one, `scan_ui` once ran until the MCP client gave up after
 * 1800s, and the agent sat idle for half an hour instead of trying another route.
 */
export class DeadlineError extends Error {}

export function withDeadline<T>(work: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new DeadlineError(
      `${what} did not finish within ${Math.round(ms / 1000)}s. The device may be locked, its WebDriverAgent stalled, or the simulator busy. ` +
      'Check with get_screenshot, use unlock_screen for a locked phone or setup_device to restart WebDriverAgent, then retry once. Do not wait on it again.'
    )), ms)
  })
  return Promise.race([work, timeout]).finally(() => clearTimeout(timer))
}
