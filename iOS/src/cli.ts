#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync, writeFileSync, symlinkSync } from 'fs'
import { join } from 'path'
import { homedir } from 'os'
import { fileURLToPath } from 'url'
import { exec, execSync } from 'child_process'
import { promisify } from 'util'
import { createInterface } from 'readline'
import { log } from './logger.js'
import { RUNTIME_HOME, runtimeRoots } from './paths.js'

const execAsync = promisify(exec)

const VERSION = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf-8')).version

// Absolute path of this script once built — what MCP client configs must point at.
const CLI_PATH = fileURLToPath(import.meta.url)

function printUsage(): void {
  process.stderr.write(`
agentcontroller-ios v${VERSION}

Usage:
  agentcontroller-ios              Start the MCP server (stdio)
  agentcontroller-ios --setup      Install helper dependencies (idb, WebDriverAgent, ax-scan)
                                   and register with Claude Code (asks for scope)
  agentcontroller-ios --setup-all  Same, registering user-wide without prompting
  agentcontroller-ios --setup-here Same, registering for the current directory only
  agentcontroller-ios --version    Print version
  agentcontroller-ios --help       Show this help
`)
}

async function prompt(question: string): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stderr })
  return new Promise(resolve => {
    rl.question(question, (answer) => {
      rl.close()
      resolve(answer.trim())
    })
  })
}

async function installDependencies(): Promise<void> {
  try {
    execSync('xcode-select -p', { stdio: 'pipe' })
  } catch {
    process.stderr.write('\n  Xcode is required. Install from the App Store or run:\n')
    process.stderr.write('    xcode-select --install\n\n')
    process.exit(1)
  }

  try {
    execSync('which brew', { stdio: 'pipe' })
  } catch {
    process.stderr.write('\n  Homebrew is required. Install from https://brew.sh\n\n')
    process.exit(1)
  }

  // Reuse helpers from a previous install root (upstream iPhone-mcp layouts)
  // by symlinking them into RUNTIME_HOME; install fresh only when absent.
  const priorRoots = runtimeRoots().filter(r => r !== RUNTIME_HOME)

  const idbPath = join(RUNTIME_HOME, 'python', 'bin', 'idb')
  const priorIdbRoot = priorRoots.find(r => existsSync(join(r, 'python', 'bin', 'idb')))
  if (existsSync(idbPath)) {
    // already installed
  } else if (priorIdbRoot) {
    mkdirSync(RUNTIME_HOME, { recursive: true })
    try { symlinkSync(join(priorIdbRoot, 'python'), join(RUNTIME_HOME, 'python')) } catch { /* ignore */ }
    const priorCompanion = join(priorIdbRoot, 'idb-companion')
    if (existsSync(priorCompanion) && !existsSync(join(RUNTIME_HOME, 'idb-companion'))) {
      try { symlinkSync(priorCompanion, join(RUNTIME_HOME, 'idb-companion')) } catch { /* ignore */ }
    }
  } else {
    process.stderr.write('\n  Installing idb (this may take a few minutes)...\n')
    mkdirSync(join(RUNTIME_HOME, 'python'), { recursive: true })
    mkdirSync(join(RUNTIME_HOME, 'idb-companion'), { recursive: true })
    try {
      process.stderr.write('    Installing idb_companion via Homebrew...\n')
      await execAsync('brew tap facebook/fb && brew install idb-companion', { timeout: 300_000 })
      process.stderr.write('    Installing fb-idb via pip...\n')
      await execAsync(`python3 -m venv "${join(RUNTIME_HOME, 'python')}" && "${join(RUNTIME_HOME, 'python', 'bin', 'pip')}" install fb-idb`, { timeout: 300_000 })
      process.stderr.write('    idb installed successfully\n')
    } catch (e) {
      process.stderr.write(`    Warning: idb installation failed: ${(e as Error).message}\n`)
      process.stderr.write('    You can install manually: brew install idb-companion && pip install fb-idb\n')
    }
  }

  const wdaPath = join(RUNTIME_HOME, 'wda-build', 'WebDriverAgent')
  const priorWdaRoot = priorRoots.find(r => existsSync(join(r, 'wda-build', 'WebDriverAgent', 'WebDriverAgent.xcodeproj')))
  if (existsSync(join(wdaPath, 'WebDriverAgent.xcodeproj'))) {
    // already installed
  } else if (priorWdaRoot) {
    mkdirSync(join(RUNTIME_HOME, 'wda-build'), { recursive: true })
    try { symlinkSync(join(priorWdaRoot, 'wda-build', 'WebDriverAgent'), wdaPath) } catch { /* ignore */ }
  } else {
    process.stderr.write('  Cloning WebDriverAgent...\n')
    mkdirSync(join(RUNTIME_HOME, 'wda-build'), { recursive: true })
    try {
      await execAsync(`git clone --depth 1 https://github.com/appium/WebDriverAgent.git "${wdaPath}"`, { timeout: 120_000 })
    } catch (e) {
      process.stderr.write(`    Warning: WDA clone failed: ${(e as Error).message}\n`)
      process.stderr.write('    Physical device support requires WDA. You can clone manually.\n')
    }
  }

  const axScanPath = join(RUNTIME_HOME, 'bin', 'ax-scan')
  const priorAxScanRoot = priorRoots.find(r => existsSync(join(r, 'bin', 'ax-scan')))
  if (existsSync(axScanPath)) {
    // already installed
  } else if (priorAxScanRoot) {
    mkdirSync(join(RUNTIME_HOME, 'bin'), { recursive: true })
    try { symlinkSync(join(priorAxScanRoot, 'bin', 'ax-scan'), axScanPath) } catch { /* ignore */ }
  } else {
    try {
      const axScanDir = join(import.meta.dirname, 'idb', 'ax-scan')
      const srcAxScanDir = join(import.meta.dirname, '..', 'src', 'idb', 'ax-scan')
      const makeDir = existsSync(join(axScanDir, 'Makefile')) ? axScanDir
        : existsSync(join(srcAxScanDir, 'Makefile')) ? srcAxScanDir
        : null
      if (makeDir) {
        await execAsync(`make -C "${makeDir}" install INSTALL_DIR="${join(RUNTIME_HOME, 'bin')}"`, { timeout: 60_000 })
      }
    } catch { /* ax-scan is optional; scan_ui falls back to idb describe-all */ }
  }
}

function writeClaudeCodeConfig(configPath: string): boolean {
  const mcpServers = {
    'agentcontroller-ios': {
      command: 'node',
      args: [CLI_PATH],
    },
  }

  try {
    let existing: Record<string, unknown> = {}
    if (existsSync(configPath)) {
      existing = JSON.parse(readFileSync(configPath, 'utf8'))
    }
    const merged = {
      ...existing,
      mcpServers: {
        ...(existing.mcpServers as Record<string, unknown> ?? {}),
        ...mcpServers,
      },
    }
    writeFileSync(configPath, JSON.stringify(merged, null, 2) + '\n')
    process.stderr.write(`    Written: ${configPath}\n`)
    return true
  } catch (e) {
    process.stderr.write(`    Warning: Could not write ${configPath}: ${(e as Error).message}\n`)
    return false
  }
}

async function runSetup(scope?: 'all' | 'here'): Promise<void> {
  await installDependencies()

  if (!scope) {
    const answer = await prompt('\n  Register MCP server:\n    1. User-wide (all projects) [recommended]\n    2. Current directory only\n  Choose (1/2): ')
    scope = answer === '2' ? 'here' : 'all'
  }

  const configPath = scope === 'here'
    ? join(process.cwd(), '.mcp.json')
    : join(homedir(), '.claude.json')
  const written = writeClaudeCodeConfig(configPath)

  if (written) {
    process.stderr.write('\n  Setup complete! Restart your AI agent to activate.\n')
  }
  process.stderr.write(`\n  For other MCP clients, register a stdio server running:\n    node ${CLI_PATH}\n\n`)
}

async function main(): Promise<void> {
  const args = process.argv.slice(2)

  if (args.includes('--help') || args.includes('-h')) {
    printUsage()
    process.exit(0)
  }

  if (args.includes('--version') || args.includes('-v')) {
    process.stderr.write(`agentcontroller-ios v${VERSION}\n`)
    process.exit(0)
  }

  if (args.includes('--setup-all')) {
    await runSetup('all')
    process.exit(0)
  }

  if (args.includes('--setup-here')) {
    await runSetup('here')
    process.exit(0)
  }

  if (args.includes('--setup')) {
    await runSetup()
    process.exit(0)
  }

  // Default: start MCP server
  const { startServer } = await import('./index.js')
  await startServer()
}

main().catch(e => {
  log('CLI', 'error', `Fatal error: ${e}`)
  process.exit(1)
})
