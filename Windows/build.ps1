param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Runtime = 'win-x64',
    [switch] $FrameworkDependent
)

$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_HOME = Join-Path $PSScriptRoot '.dotnet-cli'
$env:DOTNET_NOLOGO = '1'
$project = Join-Path $PSScriptRoot 'AgentController.Windows\AgentController.Windows.csproj'
$output = Join-Path $PSScriptRoot "publish\$Runtime"
$selfContained = if ($FrameworkDependent) { 'false' } else { 'true' }

dotnet publish $project `
    --configuration Release `
    --runtime $Runtime `
    --self-contained $selfContained `
    --output $output `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true

if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }

Write-Host "Published AgentController Windows to $output"
