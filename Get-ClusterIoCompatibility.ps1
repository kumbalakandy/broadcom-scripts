[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$vCenter,
    [System.Management.Automation.PSCredential]$Credential,
    [string[]]$ClusterName,
    [switch]$All,
    [int]$ShowNumberOfSupportedReleases = 4,
    [string]$OutputCsv,
    [switch]$SkipVersions
)

# Devices to ignore (partial or full match on device name) - from queryHostPCIInfo.ps1
$excludeDevices = @(
    "<class> System peripheral", "<class> Performance counters", "<class> PCI bridge",
    "<class> ISA bridge", "Series Chipset Family", "Ice Lake RAS", "Ice Lake IEH",
    "MSM", "UPI", "Memory Map/VT-d", "Mesh 2 PCIe"
)

#region BCG lookup (based on Check-BroadcomCompatIoDevice)
$bcgCache = @{}

function Get-BcgIoDevice {
    param(
        [Parameter(Mandatory = $true)][string]$VID,
        [Parameter(Mandatory = $true)][string]$DID,
        [Parameter(Mandatory = $true)][string]$SVID
    )

    $key = "$VID`:$DID`:$SVID"
    if ($bcgCache.ContainsKey($key)) { return $bcgCache[$key] }

    $spec = [ordered]@{
        "programId" = "io"
        "filters"   = @(
            @{ "displayKey" = "vid";  "filterValues" = @($VID) }
            @{ "displayKey" = "did";  "filterValues" = @($DID) }
            @{ "displayKey" = "svid"; "filterValues" = @($SVID) }
        )
        "keyword"   = @()
        "date"      = @{ "startDate" = $null; "endDate" = $null }
    }
    $body = $spec | ConvertTo-Json -Depth 4
    $uri  = "https://compatibilityguide.broadcom.com/compguide/programs/viewResults?limit=20&page=1&sortBy=&sortType=ASC"

    $result = [pscustomobject]@{ Status = "Not listed"; Entries = @() }
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method POST `
            -ContentType "application/json" -Body $body -TimeoutSec 60 -ErrorAction Stop
        $json = $response.Content | ConvertFrom-Json
        if ($json.data.count -gt 0) {
            $result.Status  = "Listed"
            $result.Entries = @($json.data.fieldValues)
        }
    }
    catch {
        $result.Status = "Lookup failed: $($_.Exception.Message)"
    }

    $bcgCache[$key] = $result
    return $result
}
#endregion

#region Driver / firmware collection
function ConvertTo-PciAddress {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $null }
    $a = $Address.Trim().ToLower()
    if ($a -notmatch '^[0-9a-f]{4}:') { $a = "0000:$a" }   # older builds omit the PCI domain
    return $a
}

function Get-HostIoVersionMap {
    <#
      Returns a hashtable: PCI address -> @{ Alias; Driver; DriverVersion; FirmwareVersion }
    #>
    param(
        [Parameter(Mandatory = $true)]$HostView,
        [Parameter(Mandatory = $true)]$EsxCli
    )

    $map = @{}
    $esxcli = $EsxCli

    $moduleVersions = @{}
    function Get-ModVer([string]$m) {
        if ([string]::IsNullOrWhiteSpace($m) -or $m -eq 'None') { return '' }
        if (-not $moduleVersions.ContainsKey($m)) {
            try   { $moduleVersions[$m] = [string]$esxcli.system.module.get.Invoke(@{ module = $m }).Version }
            catch { $moduleVersions[$m] = '' }
        }
        return $moduleVersions[$m]
    }
    function Get-Entry([string]$addr) {
        if (-not $map.ContainsKey($addr)) {
            $map[$addr] = [pscustomobject]@{ Alias = ''; Driver = ''; DriverVersion = ''; FirmwareVersion = '' }
        }
        return $map[$addr]
    }

    # 1. Every PCI device: driver module + module version
    try {
        foreach ($p in $esxcli.hardware.pci.list.Invoke()) {
            $addr = ConvertTo-PciAddress $p.Address
            if (-not $addr) { continue }
            $e = Get-Entry $addr
            if ($p.VMkernelName) { $e.Alias = [string]$p.VMkernelName }
            if ($p.ModuleName -and $p.ModuleName -ne 'None') {
                $e.Driver        = [string]$p.ModuleName
                $e.DriverVersion = Get-ModVer $p.ModuleName
            }
        }
    }
    catch { Write-Warning "  $($HostView.Name): esxcli hardware pci list failed: $($_.Exception.Message)" }

    # 2. NICs: driver, driver version and firmware from the NIC itself
    try {
        foreach ($nic in $esxcli.network.nic.list.Invoke()) {
            $addr = ConvertTo-PciAddress $nic.PCIDevice
            if (-not $addr) { continue }
            $e = Get-Entry $addr
            $e.Alias = [string]$nic.Name
            try {
                $info = $esxcli.network.nic.get.Invoke(@{ nicname = $nic.Name }).DriverInfo
                if ($info.Driver)          { $e.Driver          = [string]$info.Driver }
                if ($info.Version)         { $e.DriverVersion   = [string]$info.Version }
                if ($info.FirmwareVersion) { $e.FirmwareVersion = [string]$info.FirmwareVersion }
            }
            catch { }
        }
    }
    catch { Write-Warning "  $($HostView.Name): esxcli network nic list failed: $($_.Exception.Message)" }

    # vmhba -> PCI address, from the vSphere API
    $hbaPci = @{}
    foreach ($hba in $HostView.Config.StorageDevice.HostBusAdapter) {
        $addr = ConvertTo-PciAddress $hba.Pci
        if ($addr -and $hba.Device) {
            $hbaPci[$hba.Device] = $addr
            $e = Get-Entry $addr
            if (-not $e.Alias) { $e.Alias = [string]$hba.Device }
            if (-not $e.Driver -and $hba.Driver) {
                $e.Driver        = [string]$hba.Driver
                $e.DriverVersion = Get-ModVer $hba.Driver
            }
        }
    }

    # 3. Fibre Channel HBAs: firmware + driver version
    try {
        foreach ($fc in $esxcli.storage.san.fc.list.Invoke()) {
            if (-not $hbaPci.ContainsKey($fc.Adapter)) { continue }
            $e = Get-Entry $hbaPci[$fc.Adapter]
            if ($fc.FirmwareVersion) { $e.FirmwareVersion = [string]$fc.FirmwareVersion }
            # keep the module version (same source on every host) so drift detection compares like with like
            if ($fc.DriverVersion -and -not $e.DriverVersion) { $e.DriverVersion = [string]$fc.DriverVersion }
        }
    }
    catch { }   # no FC adapters or namespace not present

    # 4. NVMe adapters: firmware revision of the controller
    foreach ($hba in $HostView.Config.StorageDevice.HostBusAdapter) {
        if ($hba.Driver -notlike 'nvme*' -or -not $hbaPci.ContainsKey($hba.Device)) { continue }
        try {
            $nv = $esxcli.nvme.device.get.Invoke(@{ adapter = $hba.Device })
            if ($nv.FirmwareRevision) { (Get-Entry $hbaPci[$hba.Device]).FirmwareVersion = ([string]$nv.FirmwareRevision).Trim() }
        }
        catch { }
    }

    return $map
}

function Test-EsxTrue { param($Value) return ("$Value" -eq 'true') }

function Get-HostBootInfo {
    <#
      System (boot) disk details via esxcli "Is Boot Device", plus boot type.
      Returns a pscustomobject; fields are blank when they cannot be determined.
    #>
    param(
        [Parameter(Mandatory = $true)]$HostView,
        $EsxCli
    )

    $info = [pscustomobject][ordered]@{
        BootType          = 'Unknown'
        BootDevice        = ''
        BootDiskVendor    = ''
        BootDiskModel     = ''
        BootDiskSizeGB    = ''
        BootDiskFirmware  = ''
        BootDiskSSD       = ''
        BootDiskDriveType = ''
        BootController    = ''
        BootFsCapacityGB      = ''
        BootFsUsedGB          = ''
        BootFsFreeGB          = ''
        BootFsUsedPct         = ''
        BootDiskUnallocatedGB = ''
        OSDataUsedPct         = ''
        BootFsMaxUsedPct      = ''
        BootFsDetail          = ''
    }
    if (-not $EsxCli) { return $info }

    # Stateless / Auto Deploy hosts boot from the network
    $stateless = $false
    try {
        $bd = $EsxCli.system.boot.device.get.Invoke()
        $nic = "$($bd.BootNIC)$($bd.StatelessBootNIC)".Trim()
        if ($nic) { $stateless = $true; $info.BootType = "Network/Auto Deploy ($nic)" }
    }
    catch { }

    $disk = $null
    try {
        $disk = $EsxCli.storage.core.device.list.Invoke() |
            Where-Object { Test-EsxTrue $_.IsBootDevice } | Select-Object -First 1
    }
    catch {
        Write-Warning "  $($HostView.Name): esxcli storage core device list failed: $($_.Exception.Message)"
    }

    if ($disk) {
        $info.BootDevice        = [string]$disk.Device
        $info.BootDiskVendor    = ([string]$disk.Vendor).Trim()
        $info.BootDiskModel     = ([string]$disk.Model).Trim()
        $info.BootDiskFirmware  = ([string]$disk.Revision).Trim()
        $info.BootDiskSSD       = $(if (Test-EsxTrue $disk.IsSSD) { 'Yes' } else { 'No' })
        $info.BootDiskDriveType = [string]$disk.DriveType      # physical / logical (RAID volume); newer builds only
        if ($disk.Size -as [double]) { $info.BootDiskSizeGB = [math]::Round(([double]$disk.Size) / 1024, 1) }   # esxcli reports MB

        if (-not $stateless) {
            if     (Test-EsxTrue $disk.IsUSB)   { $info.BootType = 'USB/SD card' }
            elseif (Test-EsxTrue $disk.IsLocal) { $info.BootType = 'Local disk' }
            else                                { $info.BootType = 'SAN / remote LUN' }
        }

        # Which controller the boot disk sits behind (e.g. BOSS card, RAID controller)
        try {
            $path = $EsxCli.storage.core.path.list.Invoke(@{ device = $disk.Device }) | Select-Object -First 1
            if ($path.Adapter) {
                $hba = $HostView.Config.StorageDevice.HostBusAdapter |
                    Where-Object { $_.Device -eq $path.Adapter } | Select-Object -First 1
                $info.BootController = $(if ($hba.Model) { "$($path.Adapter) ($($hba.Model))" } else { [string]$path.Adapter })
            }
        }
        catch { }

        # Space on the boot disk
        $space = Get-BootDiskSpace -EsxCli $EsxCli -BootDevice $disk.Device -DiskSizeMB ($disk.Size -as [double])
        foreach ($p in $space.PSObject.Properties) { $info.($p.Name) = $p.Value }
    }
    elseif (-not $stateless) {
        $info.BootType = 'Not identified'
    }

    return $info
}

function Get-BootDiskSpace {
    <#
      Used/free space on the boot disk:
        - filesystems on it: bootbanks (vfat), ESX-OSData (VMFS-L / VMFSOS), any local VMFS datastore
          (esxcli storage filesystem list, matched to the disk with esxcli storage vmfs extent list)
        - unpartitioned space (disk size minus partitions, esxcli storage core device partition list)
    #>
    param($EsxCli, [string]$BootDevice, [double]$DiskSizeMB)

    $r = [pscustomobject][ordered]@{
        BootFsCapacityGB      = ''
        BootFsUsedGB          = ''
        BootFsFreeGB          = ''
        BootFsUsedPct         = ''
        BootDiskUnallocatedGB = ''
        OSDataUsedPct         = ''
        BootFsMaxUsedPct      = ''
        BootFsDetail          = ''
    }
    $gb = { param($bytes) [math]::Round(([double]$bytes) / 1GB, 1) }

    # Which VMFS / VMFS-L volumes live on the boot disk
    $volumesOnDisk = @{}
    $allExtentVolumes = @{}
    try {
        foreach ($x in $EsxCli.storage.vmfs.extent.list.Invoke()) {
            $allExtentVolumes[[string]$x.VMFSUUID] = $true
            if ($x.DeviceName -eq $BootDevice) { $volumesOnDisk[[string]$x.VMFSUUID] = $true }
        }
    }
    catch { }

    $fsOnDisk = @()
    try {
        foreach ($fs in $EsxCli.storage.filesystem.list.Invoke()) {
            if ("$($fs.Mounted)" -ne 'true') { continue }
            $type = [string]$fs.Type
            $name = [string]$fs.VolumeName
            $isOsData = ($name -like 'OSDATA*' -or $type -like 'VMFSOS*' -or $type -eq 'VMFS-L')
            $onDisk = $false
            if ($volumesOnDisk.ContainsKey([string]$fs.UUID)) { $onDisk = $true }
            elseif ($type -eq 'vfat') { $onDisk = $true }                       # bootbanks / 6.x scratch & locker live on the boot disk
            elseif ($isOsData -and -not $allExtentVolumes.ContainsKey([string]$fs.UUID)) { $onDisk = $true }   # OSData not in extent list: assume default location (boot disk)
            if (-not $onDisk) { continue }

            $size = [double]$fs.Size; $free = [double]$fs.Free
            if ($size -le 0) { continue }
            $usedPct = [math]::Round((($size - $free) / $size) * 100, 0)
            if (-not $name) { $name = [string]$fs.MountPoint }
            $fsOnDisk += [pscustomobject]@{ Name = $name; Type = $type; Size = $size; Free = $free; UsedPct = $usedPct; IsOsData = $isOsData }
        }
    }
    catch {
        Write-Warning "  esxcli storage filesystem list failed: $($_.Exception.Message)"
    }

    if ($fsOnDisk.Count) {
        $cap  = ($fsOnDisk | Measure-Object Size -Sum).Sum
        $free = ($fsOnDisk | Measure-Object Free -Sum).Sum
        $r.BootFsCapacityGB = & $gb $cap
        $r.BootFsFreeGB     = & $gb $free
        $r.BootFsUsedGB     = & $gb ($cap - $free)
        $r.BootFsUsedPct    = [math]::Round((($cap - $free) / $cap) * 100, 0)
        $r.BootFsMaxUsedPct = ($fsOnDisk | Measure-Object UsedPct -Maximum).Maximum
        $osd = $fsOnDisk | Where-Object IsOsData | Select-Object -First 1
        if ($osd) { $r.OSDataUsedPct = $osd.UsedPct }
        $r.BootFsDetail = ($fsOnDisk | Sort-Object Name | ForEach-Object {
            "{0} [{1}]: {2}/{3} GB used ({4}%)" -f $_.Name, $_.Type, (& $gb ($_.Size - $_.Free)), (& $gb $_.Size), $_.UsedPct
        }) -join "; "
    }

    # Unpartitioned space on the disk
    if ($DiskSizeMB -gt 0) {
        try {
            $parts = $EsxCli.storage.core.device.partition.list.Invoke(@{ device = $BootDevice }) |
                Where-Object { [int]$_.Partition -gt 0 }
            $partBytes = ($parts | ForEach-Object { [double]$_.Size } | Measure-Object -Sum).Sum
            if ($null -ne $partBytes) {
                $unalloc = ($DiskSizeMB * 1MB) - $partBytes
                $r.BootDiskUnallocatedGB = [math]::Max(0, (& $gb $unalloc))
            }
        }
        catch { }
    }

    return $r
}

function Join-Unique {
    param($Values)
    $u = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    return ($u -join "; ")
}
#endregion

#region Connect
if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    Write-Error "VMware PowerCLI is not installed. Run: Install-Module VMware.PowerCLI -Scope CurrentUser"
    return
}
Import-Module VMware.VimAutomation.Core -ErrorAction Stop | Out-Null

$connectedHere = $false
$existing = $global:DefaultVIServers | Where-Object { $_.Name -eq $vCenter -and $_.IsConnected }
if (-not $existing) {
    Write-Host "Connecting to $vCenter ..." -ForegroundColor Cyan
    $connectParams = @{ Server = $vCenter; ErrorAction = "Stop" }
    if ($Credential) { $connectParams.Credential = $Credential }
    try {
        Connect-VIServer @connectParams | Out-Null
        $connectedHere = $true
    }
    catch {
        Write-Error "Could not connect to ${vCenter}: $($_.Exception.Message)"
        Write-Host "Tip: for self-signed certificates run:" -ForegroundColor Yellow
        Write-Host "  Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:`$false" -ForegroundColor Yellow
        return
    }
}
#endregion

try {
    #region List clusters
    $clusters = Get-View -Server $vCenter -ViewType ClusterComputeResource -Property Name, Host |
        Sort-Object Name

    if (-not $clusters) {
        Write-Warning "No clusters found in $vCenter."
        return
    }

    $i = 0
    $clusterSummary = foreach ($c in $clusters) {
        $i++
        [pscustomobject]@{
            '#'     = $i
            Cluster = $c.Name
            Hosts   = @($c.Host).Count
        }
    }

    Write-Host "`nClusters in ${vCenter}:" -ForegroundColor Cyan
    $clusterSummary | Format-Table -AutoSize | Out-Host
    Write-Host ("Total: {0} clusters, {1} hosts`n" -f $clusters.Count, ($clusterSummary | Measure-Object Hosts -Sum).Sum)
    #endregion

    #region Choose clusters
    if ($ClusterName) {
        $selected = $clusters | Where-Object { $ClusterName -contains $_.Name }
        $missing  = $ClusterName | Where-Object { $clusters.Name -notcontains $_ }
        if ($missing) { Write-Warning "Cluster(s) not found: $($missing -join ', ')" }
    }
    elseif ($All) {
        $selected = $clusters
    }
    else {
        $answer = Read-Host "Enter cluster numbers to check (e.g. 1,3) or press Enter for ALL"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            $selected = $clusters
        }
        else {
            $idx = $answer -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
            $selected = foreach ($n in $idx) {
                if ($n -ge 1 -and $n -le $clusters.Count) { $clusters[$n - 1] }
                else { Write-Warning "Ignoring invalid choice: $n" }
            }
        }
    }

    if (-not $selected) {
        Write-Warning "No clusters selected."
        return
    }
    #endregion

    #region Collect devices and check BCG
    $report = New-Object System.Collections.Generic.List[object]
    $detail = New-Object System.Collections.Generic.List[object]
    $hostReport = New-Object System.Collections.Generic.List[object]

    foreach ($cluster in $selected) {
        $hostCount = @($cluster.Host).Count
        Write-Host "`n=== Cluster: $($cluster.Name)  ($hostCount hosts) ===" -ForegroundColor Green

        if ($hostCount -eq 0) {
            Write-Warning "Cluster has no hosts, skipping."
            continue
        }

        # Request whole objects (Hardware.BiosInfo, Capability) rather than sub-properties such as
        # Capability.UefiSecureBoot or BiosInfo.FirmwareType: PowerCLI validates property paths against
        # the server's API version, and a path that doesn't exist on older vCenter fails the whole call.
        $coreProps = @('Name', 'Hardware.PciDevice', 'Hardware.SystemInfo', 'Runtime.ConnectionState',
                       'Config.StorageDevice.HostBusAdapter', 'Config.Product')
        try {
            $vmhosts = Get-View -Server $vCenter -Id $cluster.Host `
                -Property ($coreProps + @('Hardware.BiosInfo', 'Capability')) -ErrorAction Stop
        }
        catch {
            Write-Warning "  Could not read BIOS/capability info ($($_.Exception.Message)); retrying without it. Boot mode / Secure Boot will show Unknown."
            $vmhosts = Get-View -Server $vCenter -Id $cluster.Host -Property $coreProps
        }
        $connectedCount = @($vmhosts | Where-Object { $_.Runtime.ConnectionState -eq "connected" }).Count
        $clusterHostRows = New-Object System.Collections.Generic.List[object]

        # One row per device instance per host
        $deviceRows = foreach ($h in $vmhosts) {
            if ($h.Runtime.ConnectionState -ne "connected") {
                Write-Warning "  $($h.Name) is $($h.Runtime.ConnectionState); skipping."
                continue
            }

            Write-Host "  Reading host details from $($h.Name)..."
            $esxcli = $null
            try {
                $vmhostObj = Get-VIObjectByVIView -VIView $h -ErrorAction Stop
                $esxcli    = Get-EsxCli -VMHost $vmhostObj -V2 -ErrorAction Stop
            }
            catch {
                Write-Warning "  $($h.Name): could not open esxcli ($($_.Exception.Message)); boot disk and driver/firmware details skipped."
            }

            $versionMap = @{}
            if ($esxcli -and -not $SkipVersions) {
                $versionMap = Get-HostIoVersionMap -HostView $h -EsxCli $esxcli
            }

            # Host / boot details
            $boot = Get-HostBootInfo -HostView $h -EsxCli $esxcli
            $secureBoot = $h.Capability.UefiSecureBoot
            $fwType = [string]$h.Hardware.BiosInfo.FirmwareType      # populated from ESXi 8.0 U2
            $bootMode = $(
                if ($fwType)            { $fwType.ToUpper() }
                elseif ($secureBoot)    { 'UEFI' }                    # Secure Boot implies UEFI
                else                    { 'Unknown (needs ESXi 8.0 U2+)' }
            )
            $hostRow = [pscustomobject][ordered]@{
                Cluster           = $cluster.Name
                Host              = $h.Name
                ServerVendor      = $h.Hardware.SystemInfo.Vendor
                ServerModel       = $h.Hardware.SystemInfo.Model
                BiosVersion       = $h.Hardware.BiosInfo.BiosVersion
                BiosDate          = $(if ($h.Hardware.BiosInfo.ReleaseDate) { ([datetime]$h.Hardware.BiosInfo.ReleaseDate).ToString('yyyy-MM-dd') } else { '' })
                ESXiVersion       = $h.Config.Product.Version
                ESXiBuild         = $h.Config.Product.Build
                BootMode          = $bootMode
                SecureBoot        = $(if ($null -eq $secureBoot) { 'Unknown' } elseif ($secureBoot) { 'Enabled' } else { 'Disabled' })
                BootType          = $boot.BootType
                BootDevice        = $boot.BootDevice
                BootDiskVendor    = $boot.BootDiskVendor
                BootDiskModel     = $boot.BootDiskModel
                BootDiskSizeGB    = $boot.BootDiskSizeGB
                BootDiskFirmware  = $boot.BootDiskFirmware
                BootDiskSSD       = $boot.BootDiskSSD
                BootDiskDriveType = $boot.BootDiskDriveType
                BootController    = $boot.BootController
                BootFsCapacityGB      = $boot.BootFsCapacityGB
                BootFsUsedGB          = $boot.BootFsUsedGB
                BootFsFreeGB          = $boot.BootFsFreeGB
                BootFsUsedPct         = $boot.BootFsUsedPct
                BootDiskUnallocatedGB = $boot.BootDiskUnallocatedGB
                OSDataUsedPct         = $boot.OSDataUsedPct
                BootFsMaxUsedPct      = $boot.BootFsMaxUsedPct
                BootFsDetail          = $boot.BootFsDetail
            }
            $clusterHostRows.Add($hostRow)
            $hostReport.Add($hostRow)

            foreach ($d in $h.Hardware.PciDevice) {
                $vid  = "{0:x4}" -f $d.VendorId
                $did  = "{0:x4}" -f $d.DeviceId
                $svid = "{0:x4}" -f $d.SubVendorId
                if ($svid -eq "0000") { continue }
                if ($excludeDevices | Where-Object { $d.DeviceName -like "*$_*" }) { continue }

                $pciAddr = ConvertTo-PciAddress $d.Id
                $ver = $null
                if ($pciAddr -and $versionMap.ContainsKey($pciAddr)) { $ver = $versionMap[$pciAddr] }

                [pscustomobject]@{
                    Host            = $h.Name
                    PciAddress      = $pciAddr
                    Alias           = $(if ($ver) { $ver.Alias } else { '' })
                    Vendor          = $d.VendorName
                    Device          = $d.DeviceName
                    VID             = $vid
                    DID             = $did
                    SVID            = $svid
                    Driver          = $(if ($ver) { $ver.Driver } else { '' })
                    DriverVersion   = $(if ($ver) { $ver.DriverVersion } else { '' })
                    FirmwareVersion = $(if ($ver) { $ver.FirmwareVersion } else { '' })
                }
            }
        }
        foreach ($r in $deviceRows) { $detail.Add($r) }

        if ($clusterHostRows.Count) {
            Write-Host "`n  Hosts:" -ForegroundColor Cyan
            $clusterHostRows | Format-Table Host, @{ N = 'Model'; E = { $_.ServerModel } },
                @{ N = 'ESXi'; E = { $_.ESXiVersion } }, BootMode, SecureBoot, BootType,
                @{ N = 'BootDisk'; E = { ("{0} {1}GB" -f $_.BootDiskModel, $_.BootDiskSizeGB).Trim() } },
                @{ N = 'Used GB'; E = { $_.BootFsUsedGB } }, @{ N = 'Free GB'; E = { $_.BootFsFreeGB } },
                @{ N = 'Unalloc GB'; E = { $_.BootDiskUnallocatedGB } } -AutoSize -Wrap | Out-Host

            $full = @($clusterHostRows | Where-Object { $_.BootFsMaxUsedPct -ne '' -and [int]$_.BootFsMaxUsedPct -ge 80 })
            foreach ($f in $full) {
                Write-Host ("  Warning: {0} has a boot-disk filesystem at {1}% used: {2}" -f $f.Host, $f.BootFsMaxUsedPct, $f.BootFsDetail) -ForegroundColor Yellow
            }

            $legacy = @($clusterHostRows | Where-Object { $_.BootMode -eq 'BIOS' -or $_.BootMode -like 'LEGACY*' })
            if ($legacy.Count) {
                Write-Host "  Warning: $($legacy.Count) host(s) boot in legacy BIOS mode (deprecated; plan a move to UEFI)." -ForegroundColor Yellow
            }
            $usb = @($clusterHostRows | Where-Object { $_.BootType -eq 'USB/SD card' })
            if ($usb.Count) {
                Write-Host "  Warning: $($usb.Count) host(s) boot from USB/SD card (not supported as a standalone boot device for current ESXi releases)." -ForegroundColor Yellow
            }
        }
        Write-Host "  IO devices:" -ForegroundColor Cyan

        # Collapse to unique devices per cluster
        $unique = $deviceRows | Group-Object VID, DID, SVID
        Write-Host "  Found $($unique.Count) unique devices. Checking BCG..."

        $n = 0
        $clusterRows = foreach ($g in $unique) {
            $n++
            $first = $g.Group[0]
            Write-Progress -Activity "Cluster $($cluster.Name)" -Status "$($first.Device)" `
                -PercentComplete (($n / [math]::Max($unique.Count, 1)) * 100)

            $bcg = Get-BcgIoDevice -VID $first.VID -DID $first.DID -SVID $first.SVID
            $hostsWith = @($g.Group.Host | Sort-Object -Unique)

            $brands = @(); $models = @(); $types = @(); $releases = ""
            if ($bcg.Entries.Count -gt 0) {
                $brands   = $bcg.Entries | ForEach-Object { $_.brandName }  | Sort-Object -Unique
                $models   = $bcg.Entries | ForEach-Object { $_.model.name } | Sort-Object -Unique
                $types    = $bcg.Entries | ForEach-Object { $_.deviceType } | Sort-Object -Unique
                $releases = ($bcg.Entries[0].supportedReleases.name |
                    Select-Object -First $ShowNumberOfSupportedReleases) -join ", "
            }

            # Driver/firmware across hosts; more than one value = drift within the cluster
            $drivers   = Join-Unique $g.Group.Driver
            $driverVer = Join-Unique $g.Group.DriverVersion
            $fwVer     = Join-Unique $g.Group.FirmwareVersion
            $drift = @()
            if ($driverVer -like "*;*") { $drift += "Driver" }
            if ($fwVer     -like "*;*") { $drift += "Firmware" }

            [pscustomobject][ordered]@{
                Cluster           = $cluster.Name
                ClusterHosts      = $hostCount
                Vendor            = $first.Vendor
                Device            = $first.Device
                VID               = $first.VID
                DID               = $first.DID
                SVID              = $first.SVID
                HostsWithDevice   = "{0}/{1}" -f $hostsWith.Count, $connectedCount
                Instances         = $g.Count
                Driver            = $drivers
                DriverVersion     = $driverVer
                FirmwareVersion   = $fwVer
                VersionDrift      = $(if ($drift) { $drift -join "+" } else { "" })
                BCGStatus         = $bcg.Status
                BCGBrand          = $brands -join "; "
                BCGModel          = $models -join "; "
                BCGDeviceType     = $types  -join "; "
                SupportedReleases = $releases
                Hosts             = $hostsWith -join ", "
            }
        }
        Write-Progress -Activity "Cluster $($cluster.Name)" -Completed

        $clusterRows = $clusterRows | Sort-Object BCGStatus, Vendor, Device
        if ($SkipVersions) {
            $clusterRows | Format-Table Vendor, Device, VID, DID, SVID, HostsWithDevice, BCGStatus, SupportedReleases -AutoSize -Wrap | Out-Host
        }
        else {
            $clusterRows | Format-Table Device, @{ N = 'VID:DID:SVID'; E = { "$($_.VID):$($_.DID):$($_.SVID)" } },
                @{ N = 'Hosts'; E = { $_.HostsWithDevice } }, Driver,
                @{ N = 'DriverVer'; E = { $_.DriverVersion } }, @{ N = 'Firmware'; E = { $_.FirmwareVersion } },
                @{ N = 'BCG'; E = { $_.BCGStatus } } -AutoSize -Wrap | Out-Host

            $drifted = @($clusterRows | Where-Object { $_.VersionDrift })
            if ($drifted.Count) {
                Write-Host "  Warning: $($drifted.Count) device(s) have different driver/firmware versions across hosts (see _PerHost.csv)." -ForegroundColor Yellow
            }
        }

        # Flag devices not present on every host (possible hardware inconsistency)
        $partial = $clusterRows | Where-Object { [int]($_.HostsWithDevice -split '/')[0] -lt $connectedCount }
        if ($partial) {
            Write-Host "  Note: $(@($partial).Count) device(s) are not present on every connected host in this cluster." -ForegroundColor Yellow
        }

        foreach ($r in $clusterRows) { $report.Add($r) }
    }
    #endregion

    #region Export
    if ($report.Count -gt 0) {
        if (-not $OutputCsv) {
            $safeName  = $vCenter -replace '[^\w\.-]', '_'
            $OutputCsv = Join-Path (Get-Location) ("IoCompatibility_{0}_{1}.csv" -f $safeName, (Get-Date -Format "yyyyMMdd_HHmmss"))
        }
        $report | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
        Write-Host "`nReport saved to: $OutputCsv" -ForegroundColor Cyan

        if ($detail.Count -gt 0) {
            $detailCsv = [System.IO.Path]::ChangeExtension($OutputCsv, $null).TrimEnd('.') + "_PerHost.csv"
            $detail | Sort-Object Host, PciAddress |
                Select-Object Host, PciAddress, Alias, Vendor, Device, VID, DID, SVID, Driver, DriverVersion, FirmwareVersion |
                Export-Csv -Path $detailCsv -NoTypeInformation -Encoding UTF8
            Write-Host "Per-host detail saved to: $detailCsv" -ForegroundColor Cyan
        }
    }
    if ($hostReport.Count -gt 0) {
        if (-not $OutputCsv) {
            $safeName  = $vCenter -replace '[^\w\.-]', '_'
            $OutputCsv = Join-Path (Get-Location) ("IoCompatibility_{0}_{1}.csv" -f $safeName, (Get-Date -Format "yyyyMMdd_HHmmss"))
        }
        $hostsCsv = [System.IO.Path]::ChangeExtension($OutputCsv, $null).TrimEnd('.') + "_Hosts.csv"
        $hostReport | Export-Csv -Path $hostsCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Host / boot details saved to: $hostsCsv" -ForegroundColor Cyan
    }

    $notListed = @($report | Where-Object { $_.BCGStatus -ne "Listed" })
    Write-Host ("Summary: {0} host(s) and {1} device rows across {2} cluster(s); {3} device(s) not listed or failed lookup." -f `
        $hostReport.Count, $report.Count, @($selected).Count, $notListed.Count)
    #endregion
}
finally {
    if ($connectedHere) {
        Disconnect-VIServer -Server $vCenter -Confirm:$false | Out-Null
    }
}
