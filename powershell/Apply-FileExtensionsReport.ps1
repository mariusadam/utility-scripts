<#
.SYNOPSIS
    Delete files listed in a file-extensions report for the given extensions.

.DESCRIPTION
    Reads a report produced by Get-FileExtensionsReport.ps1 (JSON) and removes
    the files associated with the extensions supplied. The script supports
    ShouldProcess so callers can use -WhatIf and -Confirm to preview actions.

.PARAMETER ReportPath
    Path to the JSON report created by Get-FileExtensionsReport.ps1.

.PARAMETER Extensions
    Semi-colon separated list of extensions to remove (e.g. "txt;log;csv").
    Do not include leading dots; leading dots are accepted and trimmed.

.EXAMPLE
    & .\Apply-FileExtensionsReport.ps1 -ReportPath .\Debug\ExtensionsReport.json -Extensions "txt;log" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateNotNullOrEmpty()]
    [string]$ReportPath,

    [Parameter(Mandatory=$true, Position=1)]
    [ValidateNotNullOrEmpty()]
    [string]$Extensions
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function ConvertTo-ExtensionList {
    param([string]$s)
    return ($s -split ';' | ForEach-Object { $_.Trim() -replace '^\.+','' } | Where-Object { $_ -ne '' } | ForEach-Object { $_.ToLower() })
}

try {
    if (-not (Test-Path -Path $ReportPath)) {
        Write-Error "Report not found: $ReportPath"
        exit 1
    }

    $raw = Get-Content -Raw -Path $ReportPath -ErrorAction Stop
    $data = $null

    try {
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to parse JSON report: $_"
        exit 1
    }

    # Ensure array
    if (-not ($data -is [System.Array])) { $data = @($data) }

    $targetExts = ConvertTo-ExtensionList -s $Extensions
    if (-not $targetExts) {
        Write-Error "No valid extensions provided"
        exit 1
    }

    Write-Information "Extensions requested for removal: $($targetExts -join ', ')"

    $toRemove = @()

    foreach ($ext in $targetExts) {
        $entries = $data | Where-Object { ($_.Extension -as [string]) -and ($_.Extension.ToLower() -eq $ext) }
        if (-not $entries) {
            Write-Information "No entries in report for extension: $ext"
            continue
        }

        foreach ($entry in $entries) {
            if ($null -eq $entry.Files) {
                Write-Information "Report entry for extension '$($entry.Extension)' has no Files list; skipping"
                continue
            }
            foreach ($f in $entry.Files) {
                if (-not [string]::IsNullOrEmpty($f)) { $toRemove += $f }
            }
        }
    }

    if (-not $toRemove) {
        Write-Information "No files found to remove for the requested extensions"
        exit 0
    }

    $removed = @()
    $failed = @()

    foreach ($filePath in $toRemove) {
        try {
            if ($PSCmdlet.ShouldProcess($filePath, 'Remove file')) {
                Remove-Item -LiteralPath $filePath -Force -ErrorAction Stop
                Write-Information "Removed: $filePath"
                $removed += $filePath
            }
            else {
                Write-Information "Skipped (ShouldProcess false): $filePath"
            }
        }
        catch {
            Write-Error "Failed to remove $($filePath): $($_)"
            $failed += @{ Path = $($filePath); Error = $($_).ToString() }
        }
    }

    # Summary
    $summary = [PSCustomObject]@{
        RequestedExtensions = $targetExts
        FilesRequested = $toRemove.Count
        FilesRemoved = $removed.Count
        Failures = $failed.Count
    }

    Write-Output $summary
    if ($failed) { Write-Information "There were $($failed.Count) failures" }

    exit 0
}
catch {
    Write-Error "Failed: $_"
    exit 1
}
