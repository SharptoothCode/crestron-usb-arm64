# Shared helpers for Install.ps1 / Uninstall.ps1. Dot-sourced, not run directly.
# Keep this file pure ASCII: Windows PowerShell 5.1 misreads BOM-less UTF-8.

$script:StateDir  = Join-Path $env:ProgramData 'ArmUsb'
$script:StateFile = Join-Path $script:StateDir 'state.json'

# Toolbox enumerates Crestron USB devices on this interface GUID (from Crestron's
# CtrnWinUsb.inf). WinUSB registers it when DeviceInterfaceGUIDs is set.
$script:CrestronInterfaceGuid = '{0251445b-4b22-4ec7-b1c9-37f36e587b13}'

# The VID/PIDs Crestron's CtrnWinUsb.inf binds. 0003/0004/0007 originally also
# load a Crestron kernel filter with no ARM64 build; here they get plain WinUSB.
$script:CrestronIdPattern = '^USB\\VID_14BE&PID_(0003|0004|0007|0009|001[0-7])\\'

# Left behind by the first (signed-package) version of this tool, which ARM64
# Windows rejects. Still cleaned up so an old install does not linger.
$script:LegacyCertSubject  = 'CN=ArmUsb Local Driver Signer'
$script:LegacyProviderName = 'DMI (unofficial ARM64 binding)'
$script:LegacyInfNames     = @('CrestronWinUsb-arm64.inf', 'CrestronRNDIS-arm64.inf')

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Relaunch the calling script elevated, forwarding its parameters. Returns $true
# if a relaunch happened (the caller should then exit).
function Invoke-SelfElevated {
    param([string]$ScriptPath, [hashtable]$BoundParameters)
    if (Test-IsAdmin) { return $false }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
    foreach ($k in $BoundParameters.Keys) {
        $v = $BoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $argList += "-$k" }
        } else {
            $argList += "-$k"; $argList += "`"$v`""
        }
    }
    $argList += '-PauseAtEnd'
    Write-Host 'Requesting administrator rights (a UAC prompt will appear)...'
    try {
        Start-Process -FilePath (Get-NativePowerShell) -Verb RunAs -ArgumentList $argList -Wait
    } catch {
        Write-Error 'Administrator rights are required and were not granted.'
    }
    return $true
}

# The real OS architecture, even when this PowerShell is itself emulated.
function Get-OsArchitecture {
    (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
}

# An x86 (emulated) PowerShell sees SysWOW64 as System32; reach the native tools.
function Get-NativeSystemDir {
    $sysnative = Join-Path $env:windir 'Sysnative'
    if (Test-Path $sysnative) { return $sysnative }
    return (Join-Path $env:windir 'System32')
}
function Get-PnpUtil          { Join-Path (Get-NativeSystemDir) 'pnputil.exe' }
function Get-NativePowerShell { Join-Path (Get-NativeSystemDir) 'WindowsPowerShell\v1.0\powershell.exe' }

function Invoke-PnpUtil {
    param([string[]]$Arguments)
    $out = & (Get-PnpUtil) @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out.Trim() }
}

function Get-DeviceProp {
    param([string]$InstanceId, [string]$Key)
    $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $Key -ErrorAction SilentlyContinue -WhatIf:$false
    # A property the device lacks comes back with no Data member at all.
    if ($p -and $p.PSObject.Properties['Data']) { $p.Data } else { $null }
}

function Get-DeviceInterfaceGuids {
    param([string]$InstanceId)
    $k = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId\Device Parameters"
    $v = Get-ItemProperty -Path $k -Name DeviceInterfaceGUIDs -ErrorAction SilentlyContinue
    if ($v) { @($v.DeviceInterfaceGUIDs) } else { @() }
}

# Crestron USB devices Windows knows about. -All includes ones not plugged in now.
function Get-CrestronUsbDevices {
    param([switch]$All)
    $devs = if ($All) { Get-PnpDevice -ErrorAction SilentlyContinue } else { Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue }
    foreach ($d in @($devs | Where-Object { $_.InstanceId -match $script:CrestronIdPattern })) {
        $guids = @(Get-DeviceInterfaceGuids $d.InstanceId)
        [pscustomobject]@{
            InstanceId = $d.InstanceId
            Name       = $d.FriendlyName
            Status     = $d.Status
            Present    = [bool](Get-DeviceProp $d.InstanceId 'DEVPKEY_Device_IsPresent')
            Service    = [string](Get-DeviceProp $d.InstanceId 'DEVPKEY_Device_Service')
            InfPath    = [string](Get-DeviceProp $d.InstanceId 'DEVPKEY_Device_DriverInfPath')
            HasGuid    = [bool]($guids | Where-Object { $_ -eq $script:CrestronInterfaceGuid })
        }
    }
}

# Is the Crestron interface registered and enabled on this device right now?
function Test-CrestronInterfaceEnabled {
    param([string]$InstanceId)
    $r = Invoke-PnpUtil @('/enum-interfaces', '/class', $script:CrestronInterfaceGuid)
    $current = $null
    foreach ($line in ($r.Output -split "`r?`n")) {
        if ($line -match '^\s*Device Instance ID:\s*(.+?)\s*$') { $current = $Matches[1] }
        elseif ($line -match '^\s*Interface Status:\s*Enabled' -and $current -and $current -ieq $InstanceId) { return $true }
    }
    return $false
}

function Read-ArmUsbState {
    if (-not (Test-Path $script:StateFile)) { return @() }
    try { @((Get-Content $script:StateFile -Raw | ConvertFrom-Json).Devices | Where-Object { $_ }) } catch { @() }
}

function Write-ArmUsbState {
    param([string[]]$Devices)
    New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
    [pscustomobject]@{
        UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Devices    = @($Devices | Sort-Object -Unique)
    } | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding ASCII
}

# --- Legacy (v1 signed package) cleanup -------------------------------------

function Get-LegacyDriverPackages {
    # Get-WindowsDriver needs elevation; a non-admin -WhatIf run just cannot see them.
    if (-not (Test-IsAdmin)) { return }
    # Reading only: keep -WhatIf from turning the DISM module import into noise.
    $WhatIfPreference = $false
    Get-WindowsDriver -Online -ErrorAction SilentlyContinue | Where-Object {
        ($script:LegacyInfNames -contains (Split-Path $_.OriginalFileName -Leaf)) -or
        ($_.ProviderName -eq $script:LegacyProviderName)
    }
}

function Get-LegacyCertificates {
    foreach ($store in 'Root', 'TrustedPublisher', 'My') {
        Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -eq $script:LegacyCertSubject }
    }
}

# Removes v1 driver packages and signer certs. Returns a list of problems.
function Remove-LegacyInstall {
    param([scriptblock]$Say = { param($m) Write-Host $m })
    $problems = @()
    foreach ($p in @(Get-LegacyDriverPackages)) {
        & $Say "Removing old driver package $($p.Driver)"
        $r = Invoke-PnpUtil @('/delete-driver', $p.Driver, '/uninstall', '/force')
        if ($r.ExitCode -ne 0 -and $r.ExitCode -ne 3010 -and @(Get-LegacyDriverPackages | Where-Object Driver -eq $p.Driver).Count) {
            $problems += "pnputil could not delete $($p.Driver) (exit $($r.ExitCode)): $($r.Output)"
        }
    }
    foreach ($c in @(Get-LegacyCertificates)) {
        $store = $c.PSParentPath | Split-Path -Leaf
        & $Say "Removing old signing certificate from $store"
        Remove-Item $c.PSPath -DeleteKey -ErrorAction SilentlyContinue
        if (Test-Path $c.PSPath) { $problems += "Could not remove certificate $($c.PSPath)" }
    }
    foreach ($leftover in 'package', 'signer.cer') {
        Remove-Item (Join-Path $script:StateDir $leftover) -Recurse -Force -ErrorAction SilentlyContinue
    }
    $problems
}

# --- Binding a device to inbox WinUSB ----------------------------------------
# Does what Device Manager > Update driver > Let me pick > Universal Serial Bus
# devices > "WinUsb Device" does: select the USB\MS_COMP_WINUSB model from
# Microsoft's own winusb.inf and install it on one specific device. Everything
# installed is Microsoft-signed, so no catalog or certificate is involved.

$script:BinderSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
namespace ArmUsb {
  public static class WinUsbBinder {
    const uint DI_ENUMSINGLEINF = 0x00010000;
    const uint DI_FLAGSEX_ALLOWEXCLUDEDDRVS = 0x00000800;
    const uint SPDIT_CLASSDRIVER = 1;
    const uint SPDRP_CLASSGUID = 8;
    const uint DICS_FLAG_GLOBAL = 1;
    const uint DIREG_DEV = 1;
    const uint DIIDFLAG_NOFINISHINSTALLUI = 2;
    const int ERROR_NO_MORE_ITEMS = 259;
    const int ERROR_INSUFFICIENT_BUFFER = 122;
    // SP_DRVINFO_DETAIL_DATA_W on 64-bit: fixed size and offset of HardwareID.
    const int DETAIL_CBSIZE = 1584;
    const int DETAIL_HWID_OFFSET = 1576;
    static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    public static readonly Guid UsbDeviceClass = new Guid("88BAE032-5A81-49f0-BC3D-A4FF138216D6");
    public const string WinUsbHardwareId = "USB\\MS_COMP_WINUSB";

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVINFO_DATA { public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SP_DEVINSTALL_PARAMS {
      public uint cbSize; public uint Flags; public uint FlagsEx;
      public IntPtr hwndParent; public IntPtr InstallMsgHandler; public IntPtr InstallMsgHandlerContext;
      public IntPtr FileQueue; public UIntPtr ClassInstallReserved; public uint Reserved;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DriverPath;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct FILETIME32 { public uint Low; public uint High; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SP_DRVINFO_DATA {
      public uint cbSize; public uint DriverType; public UIntPtr Reserved;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string MfgName;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string ProviderName;
      public FILETIME32 DriverDate; public ulong DriverVersion;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr classGuid, IntPtr hwnd);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiOpenDeviceInfoW(IntPtr set, string instanceId, IntPtr hwnd, uint flags, ref SP_DEVINFO_DATA dev);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr set, ref SP_DEVINFO_DATA dev, uint prop, byte[] buf, uint size);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiGetDeviceInstallParamsW(IntPtr set, ref SP_DEVINFO_DATA dev, ref SP_DEVINSTALL_PARAMS p);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiSetDeviceInstallParamsW(IntPtr set, ref SP_DEVINFO_DATA dev, ref SP_DEVINSTALL_PARAMS p);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiBuildDriverInfoList(IntPtr set, ref SP_DEVINFO_DATA dev, uint type);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiEnumDriverInfoW(IntPtr set, ref SP_DEVINFO_DATA dev, uint type, uint index, ref SP_DRVINFO_DATA drv);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiGetDriverInfoDetailW(IntPtr set, ref SP_DEVINFO_DATA dev, ref SP_DRVINFO_DATA drv, IntPtr buf, uint size, out uint required);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetupDiSetSelectedDriverW(IntPtr set, ref SP_DEVINFO_DATA dev, ref SP_DRVINFO_DATA drv);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SetupDiCreateDevRegKeyW(IntPtr set, ref SP_DEVINFO_DATA dev, uint scope, uint profile, uint keyType, IntPtr infHandle, string infSection);
    [DllImport("newdev.dll", SetLastError = true)]
    static extern bool DiInstallDevice(IntPtr hwnd, IntPtr set, ref SP_DEVINFO_DATA dev, ref SP_DRVINFO_DATA drv, uint flags, out int needReboot);

    static Win32Exception Err(string what) {
      int e = Marshal.GetLastWin32Error();
      return new Win32Exception(e, what + " failed: " + new Win32Exception(e).Message + " (0x" + e.ToString("X8") + ")");
    }

    static void Check64() {
      if (IntPtr.Size != 8) throw new PlatformNotSupportedException("Run this from 64-bit (native ARM64) PowerShell.");
    }

    static IntPtr Open(string instanceId, ref SP_DEVINFO_DATA dev) {
      IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
      if (set == INVALID_HANDLE_VALUE) throw Err("SetupDiCreateDeviceInfoList");
      dev = new SP_DEVINFO_DATA();
      dev.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
      if (!SetupDiOpenDeviceInfoW(set, instanceId, IntPtr.Zero, 0, ref dev)) {
        Win32Exception ex = Err("SetupDiOpenDeviceInfo(" + instanceId + ")");
        SetupDiDestroyDeviceInfoList(set);
        throw ex;
      }
      return set;
    }

    static string HardwareId(IntPtr set, ref SP_DEVINFO_DATA dev, ref SP_DRVINFO_DATA drv) {
      uint size = 4096;
      for (int attempt = 0; attempt < 3; attempt++) {
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
          Marshal.WriteInt32(buf, DETAIL_CBSIZE);
          uint required;
          if (SetupDiGetDriverInfoDetailW(set, ref dev, ref drv, buf, size, out required))
            return Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + DETAIL_HWID_OFFSET));
          int e = Marshal.GetLastWin32Error();
          if (e != ERROR_INSUFFICIENT_BUFFER) throw new Win32Exception(e, "SetupDiGetDriverInfoDetail failed (0x" + e.ToString("X8") + ")");
          size = Math.Max(required, size * 2);
        } finally { Marshal.FreeHGlobal(buf); }
      }
      throw new InvalidOperationException("SetupDiGetDriverInfoDetail kept asking for a larger buffer.");
    }

    // Finds the WinUsb Device driver in infPath for this device and, if commit is
    // true, installs it. Returns the driver's description. With commit false,
    // nothing on the system changes (the class is only checked, not set).
    public static string Bind(string instanceId, string infPath, bool commit, out bool needReboot) {
      Check64();
      needReboot = false;
      SP_DEVINFO_DATA dev = new SP_DEVINFO_DATA();
      IntPtr set = Open(instanceId, ref dev);
      try {
        if (dev.ClassGuid != UsbDeviceClass && commit) {
          // An unbound device has no class; the class driver list is built for
          // the device's class, so set it to USBDevice first, as Device Manager does.
          byte[] g = Encoding.Unicode.GetBytes(UsbDeviceClass.ToString("B") + "\0");
          if (!SetupDiSetDeviceRegistryPropertyW(set, ref dev, SPDRP_CLASSGUID, g, (uint)g.Length))
            throw Err("Setting the device class");
          SetupDiDestroyDeviceInfoList(set);
          set = IntPtr.Zero;
          set = Open(instanceId, ref dev);
        }

        SP_DEVINSTALL_PARAMS p = new SP_DEVINSTALL_PARAMS();
        p.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINSTALL_PARAMS));
        if (!SetupDiGetDeviceInstallParamsW(set, ref dev, ref p)) throw Err("SetupDiGetDeviceInstallParams");
        p.Flags |= DI_ENUMSINGLEINF;
        p.FlagsEx |= DI_FLAGSEX_ALLOWEXCLUDEDDRVS;
        p.DriverPath = infPath;
        if (!SetupDiSetDeviceInstallParamsW(set, ref dev, ref p)) throw Err("SetupDiSetDeviceInstallParams");
        if (!SetupDiBuildDriverInfoList(set, ref dev, SPDIT_CLASSDRIVER)) throw Err("SetupDiBuildDriverInfoList");

        SP_DRVINFO_DATA drv = new SP_DRVINFO_DATA();
        bool found = false;
        for (uint i = 0; ; i++) {
          drv = new SP_DRVINFO_DATA();
          drv.cbSize = (uint)Marshal.SizeOf(typeof(SP_DRVINFO_DATA));
          if (!SetupDiEnumDriverInfoW(set, ref dev, SPDIT_CLASSDRIVER, i, ref drv)) {
            if (Marshal.GetLastWin32Error() == ERROR_NO_MORE_ITEMS) break;
            throw Err("SetupDiEnumDriverInfo");
          }
          if (string.Equals(HardwareId(set, ref dev, ref drv), WinUsbHardwareId, StringComparison.OrdinalIgnoreCase)) {
            found = true;
            break;
          }
        }
        if (!found) {
          string why = dev.ClassGuid != UsbDeviceClass
            ? " (the device has no USBDevice class yet; a real install sets it first)" : "";
          throw new InvalidOperationException(infPath + " offered no " + WinUsbHardwareId + " driver for " + instanceId + why);
        }
        string desc = drv.Description + " by " + drv.ProviderName;
        if (!commit) return desc;

        if (!SetupDiSetSelectedDriverW(set, ref dev, ref drv)) throw Err("SetupDiSetSelectedDriver");
        int reboot;
        if (!DiInstallDevice(IntPtr.Zero, set, ref dev, ref drv, DIIDFLAG_NOFINISHINSTALLUI, out reboot))
          throw Err("DiInstallDevice");
        needReboot = reboot != 0;
        return desc;
      } finally {
        if (set != IntPtr.Zero) SetupDiDestroyDeviceInfoList(set);
      }
    }

    // Writes DeviceInterfaceGUIDs into the device's hardware key ("Device
    // Parameters"), creating it if needed. WinUSB reads it when the device starts.
    public static void SetInterfaceGuid(string instanceId, string guid) {
      Check64();
      SP_DEVINFO_DATA dev = new SP_DEVINFO_DATA();
      IntPtr set = Open(instanceId, ref dev);
      try {
        IntPtr h = SetupDiCreateDevRegKeyW(set, ref dev, DICS_FLAG_GLOBAL, 0, DIREG_DEV, IntPtr.Zero, null);
        if (h == INVALID_HANDLE_VALUE) throw Err("SetupDiCreateDevRegKey");
        using (SafeRegistryHandle sh = new SafeRegistryHandle(h, true))
        using (RegistryKey k = RegistryKey.FromHandle(sh)) {
          k.SetValue("DeviceInterfaceGUIDs", new string[] { guid }, RegistryValueKind.MultiString);
        }
      } finally {
        SetupDiDestroyDeviceInfoList(set);
      }
    }
  }
}
'@

function Initialize-Binder {
    if (-not ('ArmUsb.WinUsbBinder' -as [type])) { Add-Type -TypeDefinition $script:BinderSource }
}
