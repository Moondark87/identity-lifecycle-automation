#Requires -Version 5.1
<#
.SYNOPSIS
    Compares an HRIS export with Active Directory and plans (or applies) joiner,
    mover and leaver changes, matched on EmployeeID.

.DESCRIPTION
    By default the script only plans: it writes the plan to JSON, prints a summary
    and changes nothing. Add -Apply to make changes; combine with -WhatIf to see
    exactly what would run. Review items are never applied.

.EXAMPLE
    # Offline demo against the sample data (no directory access needed)
    .\scripts\Invoke-IdentitySync.ps1 -HrisCsvPath .\examples\hris-export.sample.csv `
        -DirectorySnapshotPath .\examples\directory-snapshot.sample.json -AsOf 2026-10-16

.EXAMPLE
    # Live: plan against AD, then dry-run the apply step
    .\scripts\Invoke-IdentitySync.ps1 -HrisCsvPath \\hris\exports\workers.csv -Apply -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$HrisCsvPath,
    [string]$SettingsPath,
    [string]$RoleMapPath,
    [string]$DirectorySnapshotPath,
    [string]$PlanPath = '.\identity-plan.json',
    [string]$EmailFeedPath,
    [string]$AuditLogPath = '.\identity-audit.jsonl',
    [datetime]$AsOf = (Get-Date),
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty in parameter defaults on Windows PowerShell 5.1, so resolve defaults here.
$repoRoot = Split-Path -Parent $PSScriptRoot
$configDir = Join-Path $repoRoot 'config'
if (-not $SettingsPath) { $SettingsPath = Join-Path $configDir 'settings.example.json' }
if (-not $RoleMapPath) { $RoleMapPath = Join-Path $configDir 'roles.example.json' }

Import-Module (Join-Path (Join-Path (Join-Path $repoRoot 'src') 'IdentityLifecycle') 'IdentityLifecycle.psd1') -Force

$settings = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json
$roleMap = Get-Content -Path $RoleMapPath -Raw | ConvertFrom-Json
Test-RoleMap -RoleMap $roleMap -ManagedGroupPrefix $settings.ManagedGroupPrefix | Out-Null

$hris = @(Import-Csv -Path $HrisCsvPath -Encoding UTF8)
$directory = if ($DirectorySnapshotPath) {
    @(Get-Content -Path $DirectorySnapshotPath -Raw | ConvertFrom-Json)
}
else {
    @(Get-DirectorySnapshot -SearchBase $settings.SearchBase)
}

$plan = @(New-IdentityPlan -HrisRecords $hris -DirectoryUsers $directory -RoleMap $roleMap -Settings $settings -AsOf $AsOf)
# Windows PowerShell escapes ' < > & as \uXXXX; undo that so the plan is easy to read (still valid JSON).
$json = ConvertTo-Json -InputObject $plan -Depth 6
$json = $json -replace '\\u0027', "'" -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&'
Set-Content -Path $PlanPath -Value $json -Encoding UTF8 -WhatIf:$false

Write-Host "`nIdentity plan as of $($AsOf.ToString('yyyy-MM-dd')): $($hris.Count) HRIS records, $($directory.Count) directory accounts"
$order = 'Joiner', 'Activate', 'Mover', 'Update', 'Leaver', 'Review', 'NoChange'
$plan | Group-Object Action |
    Sort-Object { [array]::IndexOf($order, $_.Name) } |
    Format-Table @{ n = 'Action'; e = { $_.Name } }, Count -AutoSize | Out-Host

$plan | Where-Object Action -ne 'NoChange' |
    Sort-Object { [array]::IndexOf($order, $_.Action) }, EmployeeID |
    Format-Table Action, EmployeeID, SamAccountName, DisplayName, Reason -AutoSize -Wrap | Out-Host
Write-Host "Plan written to $PlanPath"

if ($EmailFeedPath) {
    ConvertTo-HrisEmailFeed -DirectoryUsers $directory -ExcludeAccountPatterns @($settings.ExcludeAccountPatterns) | Export-Csv -Path $EmailFeedPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Host "HRIS email feed written to $EmailFeedPath"
}

if ($Apply) {
    if ($DirectorySnapshotPath) { throw '-Apply needs a live directory read; remove -DirectorySnapshotPath.' }
    $result = Invoke-IdentityPlan -Plan $plan -Settings $settings -AuditLogPath $AuditLogPath -WhatIf:$WhatIfPreference -Confirm:$false
    Write-Host "Applied: $($result.Applied)  Failed: $($result.Failed)  Skipped (NoChange/Review): $($result.Skipped)"
}
