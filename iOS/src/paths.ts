import { existsSync } from 'fs'
import { join } from 'path'
import { homedir } from 'os'

// Primary runtime directory for the AgentController iOS backend.
export const RUNTIME_HOME = join(homedir(), '.agentcontroller', 'ios')

// Runtime roots left behind by pre-AgentController installs. They use the same
// relative layout, so a machine that already downloaded WebDriverAgent and
// idb-companion keeps working instead of re-fetching several hundred MB. These
// names are load-bearing on existing checkouts and must not be renamed; new
// installs always go to RUNTIME_HOME. See NOTICE for provenance.
const LEGACY_RUNTIME_HOMES = ['.blitz-iphone-mcp', '.blitz']

// Roots searched for installed helpers (idb, idb_companion, ax-scan,
// WebDriverAgent) — ours first, legacy layouts as fallback.
export function runtimeRoots(): string[] {
  return [
    RUNTIME_HOME,
    ...LEGACY_RUNTIME_HOMES.map((dir) => join(homedir(), dir)),
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
