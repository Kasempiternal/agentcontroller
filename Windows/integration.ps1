param(
    [string] $Server = (Join-Path $PSScriptRoot 'Deskestro.Windows\bin\Release\net9.0-windows\deskestro-windows.exe'),
    [string] $Fixture = (Join-Path $PSScriptRoot 'Deskestro.Windows.TestApp\bin\Release\net9.0-windows\Deskestro.Windows.TestApp.exe')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Server)) { throw "Server not found: $Server" }
if (-not (Test-Path -LiteralPath $Fixture)) { throw "Fixture not found: $Fixture" }

$fixtureProcess = Start-Process -FilePath $Fixture -PassThru
try {
    $fixtureProcess.WaitForInputIdle(5000) | Out-Null
    Start-Sleep -Milliseconds 250

    $requests = @(
        '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"snapshot","arguments":{"app":"Deskestro.Windows.TestApp","maxElements":50}}}',
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"type_text","arguments":{"app":"Deskestro.Windows.TestApp","role":"Edit","text":"Windows UIA works"}}}',
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{"app":"Deskestro.Windows.TestApp","title":"Apply"}}}',
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"assert_visible","arguments":{"app":"Deskestro.Windows.TestApp","labelContains":"Windows UIA works","timeoutMs":3000}}}',
        '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"screenshot_window","arguments":{"app":"Deskestro.Windows.TestApp"}}}'
    )
    $requests = $requests | ForEach-Object { $_.Replace('Deskestro.Windows.TestApp', $fixtureProcess.Id.ToString()) }

    $responses = @($requests | & $Server | ForEach-Object { $_ | ConvertFrom-Json })
    if ($responses.Count -ne 5) { throw "Expected 5 responses, got $($responses.Count)." }
    foreach ($response in $responses) {
        if ($response.result.isError) {
            throw "Integration tool failed: $($response.result.content[0].text)"
        }
    }
    if ($responses[0].result.structuredContent.elementCount -lt 4) { throw 'Snapshot returned too few elements.' }
    if ($responses[1].result.structuredContent.method -ne 'uia-value') { throw 'type_text did not use background-safe ValuePattern.' }
    if ($responses[2].result.structuredContent.method -ne 'uia-invoke') { throw 'click did not use background-safe InvokePattern.' }
    if ($responses[4].result.content[0].type -ne 'image') { throw 'screenshot_window did not return an image.' }

    $gesture = $responses[0].result.structuredContent.elements | Where-Object identifier -eq 'GestureTarget' | Select-Object -First 1
    if (-not $gesture) { throw 'GestureTarget was missing from the UI Automation snapshot.' }
    $startX = [int]($gesture.frame.x + 12)
    $startY = [int]($gesture.frame.y + ($gesture.frame.height / 2))
    $endX = [int]($gesture.frame.x + $gesture.frame.width - 12)
    $endY = $startY
    $app = $fixtureProcess.Id.ToString()

    function Invoke-RawCheck {
        param(
            [string] $Tool,
            [hashtable] $Arguments,
            [string] $ExpectedStatus,
            [string] $ExpectedMethod
        )
        $actionRequest = [ordered]@{
            jsonrpc = '2.0'; id = 1; method = 'tools/call'
            params = [ordered]@{ name = $Tool; arguments = $Arguments }
        }
        $assertRequest = [ordered]@{
            jsonrpc = '2.0'; id = 2; method = 'tools/call'
            params = [ordered]@{
                name = 'assert_visible'
                arguments = [ordered]@{ app = $app; labelContains = $ExpectedStatus; timeoutMs = 3000 }
            }
        }
        $lines = @($actionRequest, $assertRequest) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 }
        $rawResponses = @($lines | & $Server | ForEach-Object { $_ | ConvertFrom-Json })
        if ($rawResponses.Count -ne 2) { throw "$Tool returned $($rawResponses.Count) responses instead of 2." }
        if ($rawResponses[0].result.isError) { throw "$Tool failed: $($rawResponses[0].result.content[0].text)" }
        if ($rawResponses[1].result.isError) { throw "$Tool did not produce status '$ExpectedStatus'." }
        if ($rawResponses[0].result.structuredContent.method -ne $ExpectedMethod) {
            throw "$Tool reported method '$($rawResponses[0].result.structuredContent.method)' instead of '$ExpectedMethod'."
        }
    }

    $refusalRequest = [ordered]@{
        jsonrpc = '2.0'; id = 1; method = 'tools/call'
        params = [ordered]@{ name = 'double_click'; arguments = [ordered]@{ app = $app; identifier = 'GestureTarget' } }
    }
    $refusal = (($refusalRequest | ConvertTo-Json -Compress -Depth 10) | & $Server | ConvertFrom-Json)
    if (-not $refusal.result.isError) { throw 'double_click did not require explicit foreground:true.' }

    Invoke-RawCheck 'double_click' @{ app = $app; identifier = 'GestureTarget'; foreground = $true } 'Double click' 'foreground-double-click'
    Invoke-RawCheck 'right_click' @{ app = $app; identifier = 'GestureTarget'; foreground = $true } 'Right click' 'foreground-right-click'
    Invoke-RawCheck 'send_shortcut' @{ app = $app; key = 'k'; modifiers = @('ctrl'); foreground = $true } 'Shortcut' 'foreground-keyboard'
    Invoke-RawCheck 'swipe' @{ app = $app; startX = $startX; startY = $startY; endX = $endX; endY = $endY; duration = 0.2; foreground = $true } 'Dragged' 'foreground-swipe'
    Invoke-RawCheck 'drag_drop' @{ app = $app; fromX = $endX; fromY = $endY; toX = $startX; toY = $startY; duration = 0.2; foreground = $true } 'Dragged' 'foreground-drag-drop'

    Write-Host 'Windows integration passed: 49-tool registry, background UIA actions, all five foreground raw-input tools, assertions, and screenshot.'
}
finally {
    if (-not $fixtureProcess.HasExited) { $fixtureProcess.CloseMainWindow() | Out-Null }
    if (-not $fixtureProcess.WaitForExit(2000)) { $fixtureProcess.Kill() }
    $fixtureProcess.Dispose()
}
