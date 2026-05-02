# Detect.ps1 - WinRE-Fix Detection / Health Check
# Works as: Intune Win32 detection script, or local audit
#
# exit 0 + Write-Output = WinRE healthy / compliant  (Win32: skip Install.ps1)
# exit 1 + Write-Output = WinRE unhealthy             (Win32: run Install.ps1)
#
# Configurable: update $MinBuild to match your target OS baseline.

$MinBuild = 26100   # minimum Windows build — change to target a different baseline
$LogFile = Join-Path $PSScriptRoot 'WinRE-Fix.log'

function Write-DetectLog {
    param([string]$Msg, [string]$Level = 'INFO')
    Add-Content -Path $LogFile -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][$Level] [Detect] $Msg" -Force
}

try {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = $cv.CurrentBuild
    $version = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }

    if ([int]$build -lt $MinBuild) {
        $msg = "WinRE check skipped - Build $build ($version) is below minimum ($MinBuild), not applicable"
        Write-DetectLog $msg
        Write-Output $msg
        exit 0
    }

    $reagentOut = (reagentc /info 2>&1) -join "`n"
    $isEnabled = $reagentOut -match 'Windows RE status:\s+Enabled'
    $diskNum = (Get-Partition -DriveLetter C -ErrorAction Stop).DiskNumber
    $recoveryParts = @(Get-Partition -DiskNumber $diskNum | Where-Object { $_.Type -eq 'Recovery' })

    $onDedicatedPart = $false
    $dedicatedPartNum = $null
    foreach ($rp in $recoveryParts) {
        if ($reagentOut -match "partition$($rp.PartitionNumber)\b\\Recovery") {
            $onDedicatedPart = $true
            $dedicatedPartNum = $rp.PartitionNumber
            break
        }
    }

    if ($isEnabled -and $onDedicatedPart) {
        $msg = "WinRE healthy - Build $build ($version), enabled on dedicated Recovery partition $dedicatedPartNum"
        Write-DetectLog $msg
        Write-Output $msg
        exit 0
    }

    $reason = if (-not $isEnabled) {
        'WinRE not enabled'
    }
    elseif ($recoveryParts.Count -eq 0) {
        'No Recovery partition found'
    }
    else {
        'WinRE not pointing to dedicated Recovery partition'
    }

    $msg = "WinRE unhealthy - Build $build ($version): $reason"
    Write-DetectLog $msg 'WARN'
    Write-Output $msg
    exit 1
}
catch {
    $msg = "WinRE detection error - $_"
    Write-DetectLog $msg 'ERROR'
    Write-Output $msg
    exit 1
}
