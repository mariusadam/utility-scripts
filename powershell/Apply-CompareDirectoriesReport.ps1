<#
.SYNOPSIS
    Apply a CompareDirectories report: copy files marked MissingInDestination from Source to Destination.

.DESCRIPTION
    Reads a JSON report produced by CompareDirectories-Lite.ps1 and copies every file
    whose Difference.Type equals 'MissingInDestination' from the report's Source to the report's Destination.

.PARAMETER ReportPath
    Path to the JSON report file created by CompareDirectories-Lite.ps1.

.EXAMPLE
    .\Apply-CompareDirectoriesReport.ps1 -ReportPath ..\Debug\CompareDirectories-Report.json

.EXAMPLE (dry-run)
    .\Apply-CompareDirectoriesReport.ps1 -ReportPath ..\Debug\CompareDirectories-Report.json -WhatIf

.NOTES
    The script supports -WhatIf and -Verbose (via SupportsShouldProcess).
#>

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$ReportPath
)

try {
    if (-not (Test-Path -LiteralPath $ReportPath)) {
        Write-Error "Report file not found: $ReportPath"
        exit 2
    }
    $reportDir = Split-Path -Path $ReportPath -Parent
    $raw = Get-Content -LiteralPath $ReportPath -Raw -ErrorAction Stop
    $report = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Error "Failed to read or parse report: $_"
    exit 2
}

$srcRoot = $report.Source
$dstRoot = $report.Destination

if (-not $srcRoot -or -not $dstRoot) {
    Write-Error "Report missing Source or Destination paths"
    exit 2
}

# Expand to full paths
try {
    if (-not (Test-Path -LiteralPath $srcRoot)) { throw "Source root does not exist: $srcRoot" }
    $srcRootFull = (Get-Item -LiteralPath $srcRoot).FullName
} catch {
    Write-Error $_
    exit 2
}

# Destination root may not yet exist; normalize to full path using Join-Path if relative
$dstRootFull = $dstRoot
try {
    if (Test-Path -LiteralPath $dstRoot) { $dstRootFull = (Get-Item -LiteralPath $dstRoot).FullName }
    else { $dstRootFull = (Join-Path -Path (Get-Location) -ChildPath $dstRoot) }
} catch {
    # fallback
    $dstRootFull = $dstRoot
}

$toCopy = @()
if ($report.Differences) {
    $toCopy = $report.Differences | Where-Object { $_.Type -eq 'MissingInDestination' }
}

if (-not $toCopy -or $toCopy.Count -eq 0) {
    Write-Host "No 'MissingInDestination' differences found in report."
    exit 0
}

$summary = [PSCustomObject]@{
    Total = $toCopy.Count
    Copied = 0
    Skipped = 0
    Errors = 0
}

foreach ($diff in $toCopy) {
    $rel = $diff.RelativePath
    if (-not $rel) { Write-Warning "Skipping difference with no RelativePath: $($diff | ConvertTo-Json -Compress)"; $summary.Errors++; continue }

    # Normalize relative - remove leading slashes
    $relNorm = $rel -replace '^[\\/]+',''

    $srcFull = Join-Path -Path $srcRootFull -ChildPath $relNorm
    $dstFull = Join-Path -Path $dstRootFull -ChildPath $relNorm

    if (-not (Test-Path -LiteralPath $srcFull)) {
        Write-Warning "Source file does not exist, skipping: $srcFull"
        $summary.Skipped++
        continue
    }

    $dstDir = Split-Path -Path $dstFull -Parent

    # Create destination directory if needed
    if (-not (Test-Path -LiteralPath $dstDir)) {
        if ($PSCmdlet.ShouldProcess($dstDir, 'Create directory')) {
            try { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null } catch { Write-Warning ("Failed to create dir {0}: {1}" -f $dstDir, $_); $summary.Errors++; continue }
        } else { Write-Verbose "Would create dir: $dstDir"; $summary.Skipped++; continue }
    }

    # Copy file
    if ($PSCmdlet.ShouldProcess($dstFull, "Copy '$srcFull' -> '$dstFull'")) {
        try {
            Copy-Item -LiteralPath $srcFull -Destination $dstFull -Force -ErrorAction Stop
            Write-Host "Copied: $relNorm"
            $summary.Copied++
        } catch {
            Write-Warning ("Failed to copy {0} to {1}: {2}" -f $srcFull, $dstFull, $_)
            $summary.Errors++
        }
    } else {
        Write-Verbose "Would copy: $srcFull -> $dstFull"
        $summary.Skipped++
    }
}

Write-Host "\nSummary: Total=$($summary.Total) Copied=$($summary.Copied) Skipped=$($summary.Skipped) Errors=$($summary.Errors)"

if ($summary.Errors -gt 0) { exit 1 } else { exit 0 }
