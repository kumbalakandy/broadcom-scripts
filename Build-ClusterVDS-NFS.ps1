<#
.SYNOPSIS
    Builds a vSphere cluster end to end with PowerCLI:
      1. Creates (or reuses) a Datacenter and Cluster (DRS, optional HA)
      2. Adds ESXi hosts to the cluster
      3. Creates 2 x vDS with distributed port groups
      4. Adds hosts to both vDS and migrates uplinks
      5. Migrates VMkernel adapters (vmk0 etc.) from vSS to distributed port groups
      6. Creates a dedicated NFS dvPortGroup and a VMkernel adapter per host with a static IP
      7. Mounts an NFS datastore on every host

.DESIGN (default - change in the CONFIGURATION block)
      vDS-01 (Mgmt/vMotion/VM)  : vmnic0, vmnic1  -> DVPG-Mgmt, DVPG-vMotion, DVPG-VM
      vDS-02 (Storage)          : vmnic2, vmnic3  -> DVPG-NFS (MTU 9000)

    VMkernel migration is done safely: the spare uplink moves first, then the last uplink
    moves together with the VMkernel adapters in a single operation, so host management
    connectivity is never lost.

.REQUIREMENTS
    - VMware PowerCLI 12.0+
    - All hosts use the same root password (prompted once)
    - VLAN IDs below MUST match what the physical switch ports carry, especially Mgmt
    - Jumbo frames (MTU 9000) must be enabled end to end if you keep MTU 9000 for NFS

.EXAMPLE
    .\Build-ClusterVDS-NFS.ps1
#>

[CmdletBinding()]
param()

#region ===================== CONFIGURATION - EDIT THIS SECTION =====================

$Config = @{
    # --- vCenter ---
    vCenterServer = "vcsa01.kodevirtual.com"
    vCenterUser   = "administrator@vsphere.local"

    # --- Datacenter / Cluster ---
    Datacenter    = "Lab-DC"
    Cluster       = "Lab-Cluster-02"
    EnableDRS     = $true
    DRSLevel      = "FullyAutomated"      # Manual | PartiallyAutomated | FullyAutomated
    EnableHA      = $true                 # Enabled at the end, after NFS storage is mounted

    # --- ESXi hosts (FQDN or IP) ---
    Hosts = @(
        "lab-esxi11.kodevirtual.com"
        "lab-esxi12.kodevirtual.com"
        "lab-esxi13.kodevirtual.com"
    )

    # --- Distributed switches ---
    VDSwitches = @(
        @{
            Name         = "vDS-01-Mgmt"
            Mtu          = 1500
            Uplinks      = 2
            PhysicalNics = @("vmnic0", "vmnic1")   # vmnic0 should be the one currently carrying vmk0
            PortGroups   = @(
                @{ Name = "DVPG-Mgmt";    VlanId = 0    }   # MUST match current management VLAN
                @{ Name = "DVPG-vMotion"; VlanId = 2102 }
                @{ Name = "DVPG-VM";      VlanId = 2103 }
            )
        }
        @{
            Name         = "vDS-02-Storage"
            Mtu          = 9000
            Uplinks      = 2
            PhysicalNics = @("vmnic2", "vmnic3")
            PortGroups   = @(
                @{ Name = "DVPG-NFS"; VlanId = 2104 }
            )
        }
    )

    # --- VMkernel migration: existing vmk -> distributed port group (on vDS-01) ---
    VmkMigration = @{
        "vmk0" = "DVPG-Mgmt"
        # "vmk1" = "DVPG-vMotion"     # Uncomment if hosts already have a vMotion vmk on the vSS
    }
    RemoveStandardSwitch = $true          # Remove vSwitch0 after migration if it has no VMs and no vmks left

    # --- NFS VMkernel (dedicated, one IP per host) ---
    NfsVDSwitch   = "vDS-02-Storage"
    NfsPortGroup  = "DVPG-NFS"
    NfsSubnetMask = "255.255.255.0"
    NfsVmkMtu     = 9000
    NfsVmkIPs = @{
        "lab-esxi11.kodevirtual.com" = "172.21.4.11"
        "lab-esxi12.kodevirtual.com" = "172.21.4.12"
        "lab-esxi13.kodevirtual.com" = "172.21.4.13"
    }

    # --- NFS datastore ---
    NfsDatastoreName = "NFS-DS-01"
    NfsServer        = "172.21.4.100"     # For NFS 4.1 multipath: comma separated "ip1,ip2"
    NfsExportPath    = "/mnt/pool1/vsphere"
    NfsVersion       = "3"                # "3" or "4.1"
    NfsReadOnly      = $false
}

#endregion ===========================================================================

$ErrorActionPreference = "Stop"

function Write-Step  { param($Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param($Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }
function Write-Skip  { param($Msg) Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }
function Write-Warn2 { param($Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }

#region ===================== PRE-CHECKS & CONNECT =====================

Write-Step "Pre-checks"
Import-Module VMware.VimAutomation.Core, VMware.VimAutomation.Vds -ErrorAction Stop | Out-Null
Write-Ok "PowerCLI modules loaded"

foreach ($h in $Config.Hosts) {
    if (-not $Config.NfsVmkIPs.ContainsKey($h)) { throw "No NFS VMkernel IP defined for host $h in NfsVmkIPs." }
}
$allPgNames = $Config.VDSwitches.PortGroups.Name
foreach ($pg in $Config.VmkMigration.Values + $Config.NfsPortGroup) {
    if ($allPgNames -notcontains $pg) { throw "Port group '$pg' is referenced but not defined in VDSwitches." }
}
Write-Ok "Configuration is consistent"

$vcCred   = Get-Credential -UserName $Config.vCenterUser -Message "vCenter credentials"
$hostCred = Get-Credential -UserName "root" -Message "ESXi root credentials (same for all hosts)"

Write-Step "Connecting to vCenter $($Config.vCenterServer)"
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Scope Session -Confirm:$false | Out-Null
$vc = Connect-VIServer -Server $Config.vCenterServer -Credential $vcCred
Write-Ok "Connected to $($vc.Name) (vCenter $($vc.Version))"

#endregion

try {
    #region ===================== 1. DATACENTER & CLUSTER =====================

    Write-Step "Datacenter and cluster"
    $dc = Get-Datacenter -Name $Config.Datacenter -ErrorAction SilentlyContinue
    if (-not $dc) {
        $dc = New-Datacenter -Name $Config.Datacenter -Location (Get-Folder -NoRecursion)
        Write-Ok "Created datacenter $($dc.Name)"
    } else { Write-Skip "Datacenter $($dc.Name) already exists" }

    $cluster = Get-Cluster -Name $Config.Cluster -Location $dc -ErrorAction SilentlyContinue
    if (-not $cluster) {
        $clParams = @{ Name = $Config.Cluster; Location = $dc }
        if ($Config.EnableDRS) { $clParams.DrsEnabled = $true; $clParams.DrsAutomationLevel = $Config.DRSLevel }
        $cluster = New-Cluster @clParams
        Write-Ok "Created cluster $($cluster.Name) (DRS: $($Config.EnableDRS))"
    } else { Write-Skip "Cluster $($cluster.Name) already exists" }

    #endregion

    #region ===================== 2. ADD HOSTS =====================

    Write-Step "Adding hosts to $($cluster.Name)"
    $vmHosts = @()
    foreach ($h in $Config.Hosts) {
        $vmh = Get-VMHost -Name $h -ErrorAction SilentlyContinue
        if (-not $vmh) {
            $vmh = Add-VMHost -Name $h -Location $cluster -Credential $hostCred -Force -Confirm:$false
            Write-Ok "Added $h"
        } elseif ($vmh.Parent.Name -ne $cluster.Name) {
            throw "Host $h already exists in '$($vmh.Parent.Name)', not in $($cluster.Name). Move it manually first."
        } else { Write-Skip "$h already in cluster" }

        if ($vmh.ConnectionState -ne 'Connected' -and $vmh.ConnectionState -ne 'Maintenance') {
            throw "Host $h is $($vmh.ConnectionState)."
        }
        $vmHosts += $vmh
    }

    #endregion

    #region ===================== 3. CREATE vDS & PORT GROUPS =====================

    Write-Step "Creating distributed switches and port groups"
    $vdsObjects = @{}
    foreach ($s in $Config.VDSwitches) {
        $vds = Get-VDSwitch -Name $s.Name -Location $dc -ErrorAction SilentlyContinue
        if (-not $vds) {
            $vds = New-VDSwitch -Name $s.Name -Location $dc -NumUplinkPorts $s.Uplinks -Mtu $s.Mtu `
                                -LinkDiscoveryProtocol LLDP -LinkDiscoveryProtocolOperation Both
            Write-Ok "Created $($vds.Name) (MTU $($s.Mtu), $($s.Uplinks) uplinks, version $($vds.Version))"
        } else { Write-Skip "$($vds.Name) already exists" }
        $vdsObjects[$s.Name] = $vds

        foreach ($pg in $s.PortGroups) {
            if (Get-VDPortgroup -VDSwitch $vds -Name $pg.Name -ErrorAction SilentlyContinue) {
                Write-Skip "Port group $($pg.Name) already exists"; continue
            }
            $pgParams = @{ VDSwitch = $vds; Name = $pg.Name; NumPorts = 128 }
            if ($pg.VlanId -gt 0) { $pgParams.VlanId = $pg.VlanId }
            New-VDPortgroup @pgParams | Out-Null
            Write-Ok "Created $($pg.Name) on $($vds.Name) (VLAN $($pg.VlanId))"
        }
    }

    #endregion

    #region ===================== 4 & 5. ADD HOSTS TO vDS, MIGRATE UPLINKS + VMKs =====================

    Write-Step "Adding hosts to vDS and migrating uplinks / VMkernel adapters"
    foreach ($vmh in $vmHosts) {
        Write-Host "  Host: $($vmh.Name)" -ForegroundColor White

        foreach ($s in $Config.VDSwitches) {
            $vds = $vdsObjects[$s.Name]

            if (-not (Get-VDSwitch -VMHost $vmh | Where-Object Name -eq $vds.Name)) {
                Add-VDSwitchVMHost -VDSwitch $vds -VMHost $vmh -Confirm:$false
                Write-Ok "Joined $($vds.Name)"
            } else { Write-Skip "Already a member of $($vds.Name)" }

            # Physical NICs still to migrate (not yet on this vDS)
            $pnics = foreach ($n in $s.PhysicalNics) {
                $p = Get-VMHostNetworkAdapter -VMHost $vmh -Physical -Name $n -ErrorAction SilentlyContinue
                if (-not $p) { Write-Warn2 "$n not found on $($vmh.Name) - skipped"; continue }
                $onVds = Get-VDSwitch -VMHost $vmh | Where-Object Name -eq $vds.Name |
                         Get-VMHostNetworkAdapter -VMHost $vmh -Physical -ErrorAction SilentlyContinue |
                         Where-Object Name -eq $n
                if ($onVds) { Write-Skip "$n already on $($vds.Name)" } else { $p }
            }
            $pnics = @($pnics)

            # VMkernel adapters that should land on THIS vDS
            $vmkList = @(); $vmkPgs = @()
            foreach ($entry in $Config.VmkMigration.GetEnumerator()) {
                if ($s.PortGroups.Name -notcontains $entry.Value) { continue }
                $vmk = Get-VMHostNetworkAdapter -VMHost $vmh -VMKernel -Name $entry.Key -ErrorAction SilentlyContinue
                if (-not $vmk) { Write-Warn2 "$($entry.Key) not found on $($vmh.Name)"; continue }
                if ($vmk.PortGroupName -eq $entry.Value) { Write-Skip "$($entry.Key) already on $($entry.Value)"; continue }
                $vmkList += $vmk
                $vmkPgs  += Get-VDPortgroup -VDSwitch $vds -Name $entry.Value
            }

            if ($pnics.Count -eq 0 -and $vmkList.Count -eq 0) { continue }

            if ($vmkList.Count -gt 0) {
                if ($pnics.Count -eq 0) {
                    # Uplinks already moved - migrate vmks only
                    for ($i = 0; $i -lt $vmkList.Count; $i++) {
                        Set-VMHostNetworkAdapter -VirtualNic $vmkList[$i] -PortGroup $vmkPgs[$i] -Confirm:$false | Out-Null
                        Write-Ok "Migrated $($vmkList[$i].Name) -> $($vmkPgs[$i].Name)"
                    }
                } else {
                    # Phase 1: move all but the first uplink (keeps vSS connectivity on the first)
                    $first = $pnics[0]
                    $rest  = @($pnics | Select-Object -Skip 1)
                    if ($rest.Count -gt 0) {
                        Add-VDSwitchPhysicalNetworkAdapter -DistributedSwitch $vds -VMHostPhysicalNic $rest -Confirm:$false
                        Write-Ok "Moved $($rest.Name -join ', ') to $($vds.Name)"
                    }
                    # Phase 2: move the last uplink together with the VMkernel adapters (atomic)
                    Add-VDSwitchPhysicalNetworkAdapter -DistributedSwitch $vds -VMHostPhysicalNic $first `
                        -VMHostVirtualNic $vmkList -VirtualNicPortgroup $vmkPgs -Confirm:$false
                    Write-Ok "Moved $($first.Name) + $($vmkList.Name -join ', ') -> $($vmkPgs.Name -join ', ')"
                }
            } else {
                Add-VDSwitchPhysicalNetworkAdapter -DistributedSwitch $vds -VMHostPhysicalNic $pnics -Confirm:$false
                Write-Ok "Moved $($pnics.Name -join ', ') to $($vds.Name)"
            }
        }

        # Optional cleanup of the standard switch
        if ($Config.RemoveStandardSwitch) {
            $vss = Get-VirtualSwitch -VMHost $vmh -Standard -Name "vSwitch0" -ErrorAction SilentlyContinue
            if ($vss) {
                $vssVmks = Get-VMHostNetworkAdapter -VMHost $vmh -VMKernel |
                           Where-Object { (Get-VirtualPortGroup -VirtualSwitch $vss).Name -contains $_.PortGroupName }
                $vssVMs  = Get-VM -Location $vmh | Get-NetworkAdapter |
                           Where-Object { (Get-VirtualPortGroup -VirtualSwitch $vss).Name -contains $_.NetworkName }
                if (-not $vssVmks -and -not $vssVMs) {
                    Remove-VirtualSwitch -VirtualSwitch $vss -Confirm:$false
                    Write-Ok "Removed vSwitch0"
                } else { Write-Warn2 "vSwitch0 still in use (VMkernel or VMs) - not removed" }
            }
        }
    }

    #endregion

    #region ===================== 6. NFS VMKERNEL ADAPTERS =====================

    Write-Step "Creating NFS VMkernel adapters on $($Config.NfsPortGroup)"
    $nfsVds = $vdsObjects[$Config.NfsVDSwitch]
    $nfsVmkMap = @{}
    foreach ($vmh in $vmHosts) {
        $ip = $Config.NfsVmkIPs[$vmh.Name]
        $existing = Get-VMHostNetworkAdapter -VMHost $vmh -VMKernel |
                    Where-Object { $_.PortGroupName -eq $Config.NfsPortGroup -or $_.IP -eq $ip }
        if ($existing) {
            Write-Skip "$($vmh.Name): $($existing.Name) already exists ($($existing.IP))"
            $nfsVmkMap[$vmh.Name] = $existing.Name
            continue
        }
        $vmk = New-VMHostNetworkAdapter -VMHost $vmh -VirtualSwitch $nfsVds -PortGroup $Config.NfsPortGroup `
                    -IP $ip -SubnetMask $Config.NfsSubnetMask -Mtu $Config.NfsVmkMtu -Confirm:$false
        $nfsVmkMap[$vmh.Name] = $vmk.Name
        Write-Ok "$($vmh.Name): $($vmk.Name) = $ip / $($Config.NfsSubnetMask) (MTU $($Config.NfsVmkMtu))"
    }

    # Connectivity test to NFS server through the NFS vmk (jumbo-sized, don't fragment)
    Write-Step "Testing NFS server reachability (vmkping)"
    $nfsTarget  = ($Config.NfsServer -split ',')[0].Trim()
    $pingSize   = if ($Config.NfsVmkMtu -ge 9000) { 8972 } else { 1472 }
    foreach ($vmh in $vmHosts) {
        try {
            $esxcli = Get-EsxCli -VMHost $vmh -V2
            $res = $esxcli.network.diag.ping.Invoke(@{
                host = $nfsTarget; interface = $nfsVmkMap[$vmh.Name]; count = 3; size = $pingSize; df = $true })
            if ($res.Summary.Recieved -gt 0 -or $res.Summary.Received -gt 0) {
                Write-Ok "$($vmh.Name) -> $nfsTarget OK (size $pingSize, DF)"
            } else {
                Write-Warn2 "$($vmh.Name) -> $nfsTarget FAILED at size $pingSize. Check VLAN / MTU end to end."
            }
        } catch { Write-Warn2 "$($vmh.Name): ping test error - $($_.Exception.Message)" }
    }

    #endregion

    #region ===================== 7. NFS DATASTORE =====================

    Write-Step "Mounting NFS datastore $($Config.NfsDatastoreName)"
    foreach ($vmh in $vmHosts) {
        if (Get-Datastore -VMHost $vmh -Name $Config.NfsDatastoreName -ErrorAction SilentlyContinue) {
            Write-Skip "$($vmh.Name): already mounted"; continue
        }
        $dsParams = @{
            VMHost  = $vmh
            Nfs     = $true
            Name    = $Config.NfsDatastoreName
            NfsHost = ($Config.NfsServer -split ',').Trim()
            Path    = $Config.NfsExportPath
        }
        if ($Config.NfsVersion -eq "4.1") { $dsParams.FileSystemVersion = "4.1" }
        if ($Config.NfsReadOnly)          { $dsParams.ReadOnly = $true }
        New-Datastore @dsParams | Out-Null
        Write-Ok "$($vmh.Name): mounted $($Config.NfsServer):$($Config.NfsExportPath) (NFS v$($Config.NfsVersion))"
    }

    #endregion

    #region ===================== ENABLE HA =====================

    if ($Config.EnableHA) {
        Write-Step "Enabling vSphere HA"
        $cluster = Get-Cluster -Name $Config.Cluster -Location $dc
        if (-not $cluster.HAEnabled) {
            Set-Cluster -Cluster $cluster -HAEnabled $true -HAAdmissionControlEnabled $true -Confirm:$false | Out-Null
            Write-Ok "HA enabled on $($cluster.Name)"
        } else { Write-Skip "HA already enabled" }
    }

    #endregion

    #region ===================== SUMMARY =====================

    Write-Step "Summary"
    foreach ($vmh in $vmHosts) {
        Write-Host "  $($vmh.Name)" -ForegroundColor White
        Get-VMHostNetworkAdapter -VMHost $vmh -VMKernel |
            Select-Object Name, PortGroupName, IP, SubnetMask, Mtu | Format-Table -AutoSize | Out-String | Write-Host
    }
    Get-Datastore -Name $Config.NfsDatastoreName |
        Select-Object Name, Type, @{N='CapacityGB';E={[math]::Round($_.CapacityGB)}},
                      @{N='FreeGB';E={[math]::Round($_.FreeSpaceGB)}} | Format-Table -AutoSize
    Write-Host "Build complete." -ForegroundColor Green

    #endregion
}
finally {
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}
