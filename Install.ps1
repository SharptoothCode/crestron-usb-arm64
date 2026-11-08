<#
.SYNOPSIS
    Makes Crestron USB devices usable by Crestron Toolbox on Windows on ARM (for
    example Windows 11 in Parallels on Apple Silicon).

.DESCRIPTION
    UNOFFICIAL. NOT AFFILIATED WITH CRESTRON. PROVIDED AS-IS, WITHOUT SUPPORT.

    Installs nothing of its own. For each connected Crestron USB device that has no
    driver, it:

      1. Sets the device interface GUID that Toolbox looks for.
      2. Binds the device to Microsoft's WinUSB driver (winusb.inf, which ships
         with Windows), the same as picking "WinUsb Device" in Device Manager.

    4-Series processors (CP4 etc.) instead show up as a USB network adapter,
    "RNDIS/Ethernet Gadget" (USB\VID_0525&PID_A4A2). Those are bound to Microsoft's
    "Remote NDIS Compatible Device" (rndiscmp.inf) and need no interface GUID.

    No driver package, catalog or certificate is involved, because everything
    installed is Microsoft's. Devices already on WinUSB are checked and fixed if
    the interface GUID is missing. Devices bound to some other driver are left alone.

    Windows remembers the binding per USB port. If a device shows up as an unknown
    "Crestron Device" again after you use a different port, run this again.

    Uninstall.ps1 reverses it.

.PARAMETER Force
    Run even if this is not ARM64 Windows. On x64, use Crestron's own driver instead.

.EXAMPLE
    .\Install.ps1 -WhatIf
    Shows what would be done, without administrator rights and without changing anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'lib\ArmUsb.ps1')

# A -WhatIf run only reads, so it does not need elevation.
if (-not $WhatIfPreference) {
    if (Invoke-SelfElevated -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters) { return }
}

$exitCode = 0
try {
    $arch = Get-OsArchitecture
    if ($arch -ne 'ARM64' -and -not $Force) {
        throw "This Windows is $arch, not ARM64. Use Crestron's own Toolbox USB driver on x86/x64. (-Force overrides.)"
    }
    Initialize-Binder
    $winusbInf = Join-Path $env:windir 'INF\winusb.inf'
    if (-not (Test-Path $winusbInf)) { throw "$winusbInf is missing; this Windows has no inbox WinUSB." }
    $rndisInf = Join-Path $env:windir "INF\$RndisInfName"

    # Clean up after the first version of this tool (signed package, rejected on ARM64).
    if (@(Get-LegacyCertificates).Count -or @(Get-LegacyDriverPackages).Count) {
        if ($PSCmdlet.ShouldProcess('old ArmUsb driver package and signing certificate', 'Remove')) {
            $legacyProblems = @(Remove-LegacyInstall)
            if ($legacyProblems.Count) { $legacyProblems | ForEach-Object { Write-Warning $_ } }
        }
    }

    $devices = @(Get-CrestronUsbDevices)
    if (-not $devices.Count) {
        Write-Host 'No Crestron USB device is connected. Plug one in (in Parallels: Devices >'
        Write-Host 'USB & Bluetooth > "Crestron Device", or "RNDIS/Ethernet Gadget" for a 4-Series'
        Write-Host 'processor such as a CP4), then run this again.'
        return
    }

    $bound = @(Read-ArmUsbState)
    $results = @()
    foreach ($d in $devices) {
        $id = $d.InstanceId
        $action = ''
        try {
            if ($d.Kind -eq 'RNDIS') {
                # USB-Ethernet (4-Series processors). Toolbox reaches these over
                # the network adapter, so there is no interface GUID to set.
                $replaceable = $d.Service -and $RndisReplaceable.ContainsKey($d.Service) -and
                    (Split-Path $d.InfPath -Leaf) -ieq $RndisReplaceable[$d.Service]
                if ($d.Service -ieq $RndisService) {
                    $action = 'already set up (USB network adapter)'
                } elseif ($d.Service -and -not $replaceable) {
                    $action = "skipped: uses driver '$($d.Service)', left alone"
                } else {
                    $reboot = $false
                    $desc = [ArmUsb.WinUsbBinder]::Bind($id, $rndisInf, [guid]$NetClassGuid, $RndisHardwareId, $false, [ref]$reboot)
                    $from = if ($replaceable) { " (replacing Windows' '$($d.Service)' serial driver)" } else { '' }
                    if ($PSCmdlet.ShouldProcess($id, "Bind to $desc$from")) {
                        [ArmUsb.WinUsbBinder]::Bind($id, $rndisInf, [guid]$NetClassGuid, $RndisHardwareId, $true, [ref]$reboot) | Out-Null
                        $action = if ($reboot) { "bound to RNDIS$from (restart Windows to finish)" } else { "bound to RNDIS$from (USB network adapter)" }
                    } else {
                        $action = "would bind to $desc"
                    }
                }
                if (-not $WhatIfPreference -and $action -notlike 'skipped*') {
                    $bound += $id
                    if ((Get-DeviceProp $id 'DEVPKEY_Device_Service') -ine $RndisService) {
                        throw "finished, but the device is not running $RndisService"
                    }
                }
            } elseif ($d.Service -ieq 'WINUSB') {
                if ($d.HasGuid -and (Test-CrestronInterfaceEnabled $id)) {
                    $action = 'already set up'
                } elseif ($PSCmdlet.ShouldProcess($id, 'Set Toolbox interface GUID and restart device')) {
                    [ArmUsb.WinUsbBinder]::SetInterfaceGuid($id, $CrestronInterfaceGuid)
                    $r = Invoke-PnpUtil @('/restart-device', $id)
                    if ($r.ExitCode -ne 0) { throw "restart failed (exit $($r.ExitCode)): $($r.Output)" }
                    $action = 'on WinUSB; interface GUID added'
                } else {
                    $action = 'would add interface GUID'
                }
            } elseif ($d.Service) {
                $action = "skipped: uses driver '$($d.Service)', left alone"
            } else {
                $reboot = $false
                $desc = [ArmUsb.WinUsbBinder]::Bind($id, $winusbInf, $false, [ref]$reboot)
                if ($PSCmdlet.ShouldProcess($id, "Bind to $desc")) {
                    [ArmUsb.WinUsbBinder]::SetInterfaceGuid($id, $CrestronInterfaceGuid)
                    [ArmUsb.WinUsbBinder]::Bind($id, $winusbInf, $true, [ref]$reboot) | Out-Null
                    if (-not (Test-CrestronInterfaceEnabled $id)) {
                        Invoke-PnpUtil @('/restart-device', $id) | Out-Null
                    }
                    $action = if ($reboot) { 'bound to WinUSB (restart Windows to finish)' } else { 'bound to WinUSB' }
                } else {
                    $action = "would bind to $desc"
                }
            }
            if ($d.Kind -ne 'RNDIS' -and -not $WhatIfPreference -and $action -notlike 'skipped*') {
                $bound += $id
                if (-not (Test-CrestronInterfaceEnabled $id)) {
                    throw 'finished, but Toolbox interface is not enabled on the device'
                }
            }
        } catch {
            $action = "FAILED: $($_.Exception.Message)"
            $exitCode = 1
        }
        $results += [pscustomobject]@{ Device = $id; Result = $action }
    }

    if (-not $WhatIfPreference) { Write-ArmUsbState -Devices $bound }

    Write-Host ''
    $results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    if ($devices.Count -gt 1) {
        Write-Host 'Tip: Toolbox Learn IR uses the first Crestron device it finds. Connect only the'
        Write-Host 'IR learner while learning, or it reports "An invalid device is connected".'
    }
    if ($exitCode -eq 0 -and -not $WhatIfPreference) {
        if (@($results | Where-Object { $_.Result -notlike 'skipped*' }).Count) {
            Write-Host 'Done. Open Toolbox and connect over USB.' -ForegroundColor Green
        } else {
            Write-Host 'Nothing was changed: every device found already uses another driver.' -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "INSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    if ($PauseAtEnd) { Read-Host 'Press Enter to close' | Out-Null }
}
exit $exitCode
