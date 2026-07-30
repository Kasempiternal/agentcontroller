import { existsSync } from 'fs'
import { join } from 'path'
import { homedir } from 'os'

// Primary runtime directory for the AgentController iOS backend.
export const RUNTIME_HOME = join(homedir(), '.agentcontroller', 'ios')

// Roots searched for installed helpers (idb, idb_companion, ax-scan,
// WebDriverAgent). The upstream project (blitzdotdev/iPhone-mcp) installed
// into ~/.blitz-iphone-mcp and ~/.blitz with the same relative layout; keeping
// them as fallbacks means an existing install keeps working without
// re-downloading anything.
export function runtimeRoots(): string[] {
  return [
    RUNTIME_HOME,
    join(homedir(), '.blitz-iphone-mcp'),
    join(homedir(), '.blitz'),
  ]
}

// Resolve a path under the first runtime root where it exists, else null.
export function resolveRuntimeFile(...segments: string[]): string | null {
  for (const root of runtimeRoots()) {
    const candidate = join(root, ...segments)
    if (existsSync(candidate)) return candidate
  }
  return null
}
