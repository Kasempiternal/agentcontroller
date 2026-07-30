param(
    [string] $Server = (Join-Path $PSScriptRoot 'AgentController.Windows\bin\Release\net9.0-windows\agentcontroller-windows.exe')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Server)) {
    throw "Server not found: $Server. Build the Release configuration first."
}

$requests = @(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}',
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"check_permissions","arguments":{}}}'
)

$responses = @($requests | & $Server | ForEach-Object { $_ | ConvertFrom-Json })
if ($responses.Count -ne 3) { throw "Expected 3 MCP responses, got $($responses.Count)." }
if ($responses[0].result.serverInfo.name -ne 'agentcontroller-windows') { throw 'Initialize response has the wrong server name.' }
if ($responses[1].result.tools.Count -lt 20) { throw 'Tool registry is unexpectedly incomplete.' }
if ($responses[2].result.isError) { throw 'check_permissions returned an MCP error.' }

Write-Host "MCP smoke passed with $($responses[1].result.tools.Count) tools."
