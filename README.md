# Rebuild-WinREPartition

<!-- BADGES:START -->
[![License](https://img.shields.io/github/license/5a9awneh/Rebuild-WinREPartition)](LICENSE) [![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/en-us/powershell/) [![Windows](https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white)](https://www.microsoft.com/windows) [![Last Commit](https://img.shields.io/github/last-commit/5a9awneh/Rebuild-WinREPartition)](https://github.com/5a9awneh/Rebuild-WinREPartition/commits/main) [<img src="https://madebyhuman.iamjarl.com/badges/loop-white.svg" alt="Human in the Loop" height="20">](https://madebyhuman.iamjarl.com)
<!-- BADGES:END -->

Silently rebuilds the Windows Recovery Environment (WinRE) partition on Windows 11 devices where it is absent. Restores **Reset this PC**, **Autopilot Reset**, and all advanced recovery options with no user interaction and no reboot required.

Designed for bulk deployment via **Intune Win32 app**. Also runs locally via `Run-Local.bat`.

---

## ⚠️ Before You Start — Supplying `winre.wim`

`winre.wim` is **required but not included in this repository** — you must supply it and place it in the same folder as the scripts before deploying.

> **Build match required:** The WIM must match the Windows version on your target devices. The minimum supported build is set by `$MinBuild` in `Install.ps1` and `Detect.ps1` (default: `26100` / Windows 11 24H2). Update `$MinBuild` in both files if targeting a different baseline.
>
> Check target build: **Start → `winver`** or **Settings → System → About**.

### Option A — USB or DVD installation media *(easiest)*

Plug in a Windows 11 installation USB or DVD. Open `sources\install.wim` (or `install.esd`) with [7-Zip](https://www.7-zip.org) (right-click → **7-Zip → Open archive**), navigate to `1\Windows\System32\Recovery\`, and extract `winre.wim` directly into the scripts folder.

### Option B — Download a Windows 11 ISO

> Microsoft's download page shows a Media Creation Tool to Windows users. A User-Agent spoof reveals the direct ISO download link. **Official source only.**

1. Install a User-Agent switcher extension (Chrome or Firefox)
2. Set your UA to any non-Windows string (e.g. iOS Safari or Android Chrome)
3. Visit [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11) — the page now shows a direct ISO download
4. Mount the ISO (double-click in Explorer)
5. Open `sources\install.wim` (or `install.esd`) with [7-Zip](https://www.7-zip.org)
6. Navigate to `1\Windows\System32\Recovery\` and extract `winre.wim` into the scripts folder

### Option C — Copy from a healthy machine (same build)

1. On the source machine, verify WinRE is enabled:
   ```
   reagentc /info
   ```
   Status must show **Windows RE status: Enabled**
2. Copy `C:\Windows\System32\Recovery\WindowsRE\winre.wim` into the scripts folder

---

## ⚙️ Requirements

- Windows 11 24H2 (build ≥ 26100) — configurable via `$MinBuild`
- GPT / UEFI disk layout
- At least 1 GB of free shrinkable space on C:
- Administrator rights (local) or SYSTEM context (Intune)
- PowerShell 5.1 (built-in)
- `winre.wim` placed in the scripts folder (see above)

---

## 🚀 Usage

### Intune Win32 App — Bulk Deployment

1. Place `Install.ps1`, `Detect.ps1`, and `winre.wim` in the same folder
2. Package with [IntuneWinAppUtil](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool):
   ```
   IntuneWinAppUtil.exe -c <folder> -s Install.ps1 -o <output>
   ```
3. In Intune, create a **Win32 app**:
   - **Install command:** `powershell.exe -ExecutionPolicy Bypass -NoProfile -File Install.ps1`
   - **Detection rule:** Custom script → `Detect.ps1`
   - **Run as:** SYSTEM
4. Assign to the target device group

Devices where WinRE is already healthy are automatically skipped.

### Run Locally

Double-click **`Run-Local.bat`** — UAC elevation is handled automatically.

### Audit Only (no changes)

Run `Detect.ps1` directly to check WinRE health on any device without making changes. Outputs a status message and exits `0` (healthy) or `1` (needs rebuild).

> **Notes:**
> - No reboot required — changes take effect immediately after the script completes
> - **Logs:** Local runs write `WinRE-Fix.log` to the scripts folder. Intune deployments write to the app's staging directory; for post-run access check the IME log at `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\` or retrieve via **Intune → Device → Diagnostics**

---

## 🔧 How It Works

### `Install.ps1`

Rebuilds the WinRE partition end-to-end in 12 steps:

| Step | Action |
|------|--------|
| 1 | Build guard — exits cleanly on unsupported builds without making changes |
| 2 | Idempotency check — skips entirely if WinRE is already enabled on a dedicated Recovery partition |
| 3 | Orphan guard — detects a leftover ~1 GB partition from a prior interrupted run; aborts rather than double-shrinking C: |
| 4 | Capacity check — verifies C: has at least 1 GB of shrinkable space |
| 5 | Disables WinRE (`reagentc /disable`) — required before any partition changes |
| 6 | DiskPart — shrinks C: by 1024 MB, creates and formats the new Recovery partition |
| 7 | Mounts the partition via directory (`C:\WinREAccess\`) — avoids drive-letter revocation on hidden partitions |
| 8 | Copies `winre.wim` to `<partition>\Recovery\WindowsRE\winre.wim` |
| 9 | Registers and enables WinRE (`reagentc /setreimage` + `reagentc /enable`) |
| 10 | Unmounts the temp directory |
| 11 | Sets GPT type GUID (`de94bba4-...`) and hidden + required attributes — hides the partition from Explorer |
| 12 | Final verification — confirms `Windows RE status: Enabled` and correct partition; exits `1` on any mismatch |

### `Detect.ps1`

Used as both the **Intune Win32 detection script** and a **standalone audit tool**. Reports a device as compliant only when all three conditions are true:

1. `reagentc /info` reports **Windows RE status: Enabled**
2. A **Recovery-type partition** exists on the same physical disk as C:
3. The `reagentc` registered path references that **specific partition** (not `C:\Windows\System32\Recovery\`)

Devices below `$MinBuild` report as compliant — no install triggered.

---

## ⚠️ Warnings & Limitations

- **GPT / UEFI only** — MBR disks are not supported
- **C: reduced by 1 GB** — the recovery partition is hidden and not surfaced in Explorer
- **Idempotent** — safe to re-run; already-compliant devices exit without changes
- **`winre.wim` not included** — must be supplied before deployment (see top of this README)
- **Does not fix hardware or firmware issues** — if Reset this PC fails after remediation, check for BIOS and driver updates
