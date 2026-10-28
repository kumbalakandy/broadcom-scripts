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
    param([Parameter(Mandatory = $true)]$HostView)

    $map = @{}
    try {
        $vmhostObj = Get-VIObjectByVIView -VIView $HostView -ErrorAction Stop
        $esxcli    = Get-EsxCli -VMHost $vmhostObj -V2 -ErrorAction Stop
    }
    catch {
        Write-Warning "  $($HostView.Name): could not open esxcli ($($_.Exception.Message)); versions skipped."
        return $map
    }

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
            if ($fc.DriverVersion)   { $e.DriverVersion   = [string]$fc.DriverVersion }
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

    foreach ($cluster in $selected) {
        $hostCount = @($cluster.Host).Count
        Write-Host "`n=== Cluster: $($cluster.Name)  ($hostCount hosts) ===" -ForegroundColor Green

        if ($hostCount -eq 0) {
            Write-Warning "Cluster has no hosts, skipping."
            continue
        }

        $vmhosts = Get-View -Server $vCenter -Id $cluster.Host `
            -Property Name, Hardware.PciDevice, Hardware.SystemInfo, Runtime.ConnectionState, Config.StorageDevice.HostBusAdapter
        $connectedCount = @($vmhosts | Where-Object { $_.Runtime.ConnectionState -eq "connected" }).Count

        # One row per device instance per host
        $deviceRows = foreach ($h in $vmhosts) {
            if ($h.Runtime.ConnectionState -ne "connected") {
                Write-Warning "  $($h.Name) is $($h.Runtime.ConnectionState); skipping."
                continue
            }

            $versionMap = @{}
            if (-not $SkipVersions) {
                Write-Host "  Reading drivers/firmware from $($h.Name)..."
                $versionMap = Get-HostIoVersionMap -HostView $h
            }

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
                @{ N = 'Hosts'; E = { $_.HostsWithDevice } }, Driver, DriverVersion, FirmwareVersion,
                @{ N = 'Drift'; E = { $_.VersionDrift } }, BCGStatus -AutoSize -Wrap | Out-Host

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

        $notListed = @($report | Where-Object { $_.BCGStatus -ne "Listed" })
        Write-Host ("Summary: {0} device rows across {1} cluster(s); {2} not listed or failed lookup." -f `
            $report.Count, @($selected).Count, $notListed.Count)
    }
    #endregion
}
finally {
    if ($connectedHere) {
        Disconnect-VIServer -Server $vCenter -Confirm:$false | Out-Null
    }
}
