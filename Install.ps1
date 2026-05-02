#Requires -RunAsAdministrator

# Install.ps1 - WinRE Recovery Partition Rebuild
# Tested: Windows 11 24H2+ (build 26100+), GPT/UEFI, SYSTEM context
# Deploy as Intune Win32 app alongside winre.wim

$ErrorActionPreference = 'Stop'
$LogFile = Join-Path $PSScriptRoot 'WinRE-Fix.log'
$WimSource = Join-Path $PSScriptRoot 'winre.wim'
$RecoveryGPTID = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
$RecoverySizeMB = 1024
$MinBuild = 26100   # minimum Windows build — change to target a different baseline

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][$Level] $Msg"
    Add-Content -Path $LogFile -Value $line -Force
}

function Invoke-DiskPart {
    param([string]$Script)
    $tmp = "$env:SystemRoot\Temp\winre-dp-$([guid]::NewGuid().ToString('N')).txt"
    try {
        $Script | Set-Content $tmp -Encoding ASCII
        $out = diskpart /s $tmp 2>&1
        $out | ForEach-Object { Write-Log "  [diskpart] $_" }
        return $out
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

try {
    Write-Log "=== WinRE-Fix started | Host: $env:COMPUTERNAME ==="

    # --- Build check ---
    $build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
    Write-Log "OS Build: $build"
    if ([int]$build -lt $MinBuild) {
        Write-Log "Unsupported build $build (requires $MinBuild+) - skipping" 'WARN'
        exit 0
    }

    # --- Idempotency check ---
    $reagentOut = (reagentc /info 2>&1) -join "`n"
    $isEnabled = $reagentOut -match 'Windows RE status:\s+Enabled'
    $cPart = Get-Partition -DriveLetter C
    $diskNum = $cPart.DiskNumber
    $cPartNum = $cPart.PartitionNumber
    $existingRec = @(Get-Partition -DiskNumber $diskNum | Where-Object { $_.Type -eq 'Recovery' })

    if ($isEnabled -and $existingRec.Count -gt 0) {
        foreach ($rp in $existingRec) {
            if ($reagentOut -match "partition$($rp.PartitionNumber)\b\\Recovery") {
                Write-Log "WinRE already enabled on dedicated partition $($rp.PartitionNumber) - nothing to do"
                exit 0
            }
        }
    }

    $wimSize = (Get-Item $WimSource).Length
    if ($wimSize -lt 100MB) {
        Write-Log "winre.wim is suspiciously small ($([math]::Round($wimSize/1MB))MB) - aborting" 'ERROR'; exit 1
    }
    Write-Log "winre.wim size: $([math]::Round($wimSize/1MB))MB - OK"

    # --- Check if recovery partition already exists (resume after partial failure) ---
    $skipPartitionCreate = $existingRec.Count -gt 0
    if ($skipPartitionCreate) {
        Write-Log "Recovery partition already exists (Partition $($existingRec[0].PartitionNumber)) - skipping shrink/create"
    }

    # --- Orphan guard: detect ~1GB Basic partition left by a power-cut mid-DiskPart ---
    if (-not $skipPartitionCreate) {
        $orphan = Get-Partition -DiskNumber $diskNum |
        Where-Object { $_.Type -eq 'Basic' -and $_.Size -ge 900MB -and $_.Size -le 1200MB -and $_.Offset -gt $cPart.Offset }
        if ($orphan) {
            Write-Log "Orphaned ~1GB Basic partition found (Partition $($orphan.PartitionNumber)). Prior partial run detected. Manual disk cleanup required before re-running." 'ERROR'
            exit 1
        }
    }

    # --- Pre-shrink capacity check (only if creating new partition) ---
    if (-not $skipPartitionCreate) {
        $cSize = $cPart.Size
        $supported = Get-PartitionSupportedSize -DriveLetter C
        $shrinkable = $cSize - $supported.SizeMin
        Write-Log "C: size: $([math]::Round($cSize/1GB,1))GB | Shrinkable: $([math]::Round($shrinkable/1MB))MB"
        if ($shrinkable -lt ($RecoverySizeMB * 1MB)) {
            Write-Log "C: cannot shrink by ${RecoverySizeMB}MB (only $([math]::Round($shrinkable/1MB))MB available)" 'ERROR'; exit 1
        }
    }

    # --- Set up temp directory mount path ---
    $mountDir = 'C:\WinREAccess'
    Write-Log "Temp mount path: $mountDir"

    # --- Disable WinRE (required before partition changes) ---
    if ($isEnabled) {
        Write-Log "Disabling WinRE..."
        reagentc /disable 2>&1 | ForEach-Object { Write-Log "  [reagentc] $_" }
    }

    # --- DiskPart: shrink C: + create, or assign letter to existing partition ---
    if (-not $skipPartitionCreate) {
        Write-Log "Creating recovery partition..."
        $dpOut = Invoke-DiskPart @"
select disk $diskNum
select partition $cPartNum
shrink desired=$RecoverySizeMB minimum=$RecoverySizeMB
create partition primary size=$RecoverySizeMB
format fs=ntfs quick label=Recovery
exit
"@
        if ($dpOut -match 'DiskPart has encountered an error|Virtual Disk Service error|is not allowed') {
            Write-Log "DiskPart reported an error during partition creation - aborting" 'ERROR'; exit 1
        }
    }
    else {
        Write-Log "Using existing recovery partition $($existingRec[0].PartitionNumber) - will mount via directory..."
        $newPart = Get-Partition -DiskNumber $diskNum -PartitionNumber $existingRec[0].PartitionNumber
    }

    if (-not $skipPartitionCreate) {
        Start-Sleep -Seconds 3
        # --- Verify new partition was created ---
        $newPart = Get-Partition -DiskNumber $diskNum | Sort-Object Offset | Select-Object -Last 1
        if (-not $newPart -or $newPart.PartitionNumber -eq $cPartNum) {
            Write-Log "New recovery partition not found after DiskPart - aborting" 'ERROR'; exit 1
        }
    }
    Write-Log "Recovery partition: Partition $($newPart.PartitionNumber)"

    # --- Mount partition to temp directory ---
    New-Item $mountDir -ItemType Directory -Force | Out-Null
    Add-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $newPart.PartitionNumber -AccessPath "$mountDir\" -ErrorAction Stop
    Write-Log "Partition $($newPart.PartitionNumber) mounted at $mountDir"

    # --- Copy winre.wim to recovery partition ---
    $destDir = "$mountDir\Recovery\WindowsRE"
    New-Item $destDir -ItemType Directory -Force | Out-Null

    # Clear restrictive ACLs on existing partition content (existing recovery partitions
    # protect Recovery\WindowsRE with deny-write ACLs that block Copy-Item even as SYSTEM)
    if ($skipPartitionCreate) {
        Write-Log "Taking ownership of $destDir to allow overwrite..."
        takeown /f "$destDir" /r /d y 2>&1 | ForEach-Object { Write-Log "  [takeown] $_" }
        icacls "$destDir" /grant "BUILTIN\Administrators:(OI)(CI)F" /t /q 2>&1 | ForEach-Object { Write-Log "  [icacls] $_" }
        # Also clear read-only attribute on existing winre.wim if present
        $existingWim = "$destDir\winre.wim"
        if (Test-Path $existingWim) {
            Set-ItemProperty $existingWim -Name Attributes -Value ([System.IO.FileAttributes]::Normal)
        }
    }

    Write-Log "Copying winre.wim to $destDir ..."
    Copy-Item $WimSource "$destDir\winre.wim" -Force
    Write-Log "Copy complete"

    # --- Register and enable WinRE ---
    Write-Log "Running reagentc /setreimage..."
    reagentc /setreimage /path "$mountDir\Recovery\WindowsRE" 2>&1 | ForEach-Object { Write-Log "  [reagentc] $_" }
    Write-Log "Running reagentc /enable..."
    reagentc /enable 2>&1 | ForEach-Object { Write-Log "  [reagentc] $_" }

    # --- Unmount temp directory ---
    Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $newPart.PartitionNumber -AccessPath "$mountDir\" -ErrorAction SilentlyContinue
    Remove-Item $mountDir -Force -ErrorAction SilentlyContinue

    # --- Finalize partition type and GPT attributes (new partition only) ---
    if (-not $skipPartitionCreate) {
        Write-Log "Finalizing recovery partition type and attributes..."
        $dpOut = Invoke-DiskPart @"
select disk $diskNum
select partition $($newPart.PartitionNumber)
set id=$RecoveryGPTID
gpt attributes=0x8000000000000001
exit
"@
        if ($dpOut -match 'DiskPart has encountered an error|Virtual Disk Service error|is not allowed') {
            Write-Log "DiskPart reported an error finalizing partition - aborting" 'ERROR'; exit 1
        }
    }

    # --- Final verification ---
    $finalOut = (reagentc /info 2>&1) -join "`n"
    Write-Log "=== reagentc /info output ===`n$finalOut"

    if ($finalOut -match 'Windows RE status:\s+Enabled') {
        if (-not ($finalOut -match "partition$($newPart.PartitionNumber)\b\\Recovery")) {
            Write-Log "WinRE enabled but registered on wrong partition (expected partition $($newPart.PartitionNumber)) - aborting" 'ERROR'
            exit 1
        }
        Write-Log "SUCCESS: WinRE enabled on partition $($newPart.PartitionNumber)"
        exit 0
    }
    else {
        Write-Log "FAILED: WinRE not enabled after script completion" 'ERROR'
        exit 1
    }

}
catch {
    Write-Log "UNHANDLED EXCEPTION: $_" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    if ($newPart) {
        try {
            Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $newPart.PartitionNumber -AccessPath "$mountDir\" -ErrorAction SilentlyContinue
            Remove-Item $mountDir -Force -ErrorAction SilentlyContinue
        }
        catch {}
    }
    exit 1
}
