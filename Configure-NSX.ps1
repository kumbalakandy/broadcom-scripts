<#
.SYNOPSIS
    End-to-end NSX 4.x configuration with PowerShell + PowerCLI.

    PowerCLI  -> vCenter lookups (VDS UUID/uplinks, MoRefs), VDS MTU, Edge trunk port groups
    NSX API   -> Policy API (PATCH = idempotent) + MP API where Policy has no equivalent

    Steps
      1.  IP pools for Host TEP and Edge TEP
      2.  Add Compute Manager (vCenter) and wait for UP / REGISTERED
      3.  Uplink profiles (Host + Edge)
      4.  Transport Zones (Overlay + VLAN)
      5.  Transport Node Profile (VDS mode)
      6.  Apply TNP to the cluster and wait for SUCCESS
      7.  Deploy a single Edge node (+ single-member Edge Cluster, required by T0)
      8.  BGP uplink VLAN segment
      9.  Tier-0 gateway + uplink interface
      10. BGP + neighbor (waits for ESTABLISHED)
      11. Tier-1 gateway connected to T0
      12. Three overlay segments on T1

.NOTES
    - Re-runnable: Policy objects use PATCH; MP objects (compute manager, edge, edge cluster)
      are checked by name first.
    - Host TEP VLAN and Edge TEP VLAN MUST be different when the Edge VM runs on hosts
      prepared on the same VDS (or route between them).
    - VDS MTU must be >= 1700 for Geneve; the script raises it to VdsMtu if lower.
      The physical switches must support that MTU.
    - Tested API shape: NSX 4.1 / 4.2.

.EXAMPLE
    .\Configure-NSX.ps1
#>

[CmdletBinding()]
param()

#region ===================== CONFIGURATION - EDIT THIS SECTION =====================

$Config = @{
    # --- NSX Manager ---
    NsxManager      = "nonfed-nsx01.arkvcfimp.kodevirtual.com"
    NsxUser         = "admin"

    # --- vCenter (Compute Manager) ---
    vCenterServer   = "vcsa01.kodevirtual.com"
    vCenterUser     = "administrator@vsphere.local"
    ComputeMgrName  = "vcsa01"

    # --- Host preparation ---
    Cluster         = "Lab-Cluster-02"          # Cluster to prepare with the TNP
    VDSwitch        = "vDS-01-Mgmt"             # VDS used for NSX (must be VDS 7.0+)
    VdsMtu          = 9000                      # Raised only if current MTU < 1700

    # --- 1. IP pools ---
    HostTepPool = @{ Id = "host-tep-pool"; Cidr = "172.21.5.0/24"; Gateway = "172.21.5.1"; Start = "172.21.5.11"; End = "172.21.5.50" }
    EdgeTepPool = @{ Id = "edge-tep-pool"; Cidr = "172.21.6.0/24"; Gateway = "172.21.6.1"; Start = "172.21.6.11"; End = "172.21.6.30" }

    # --- 3. Uplink profiles ---
    HostTepVlan     = 2105
    EdgeTepVlan     = 2106
    HostUplinkProfile = "host-uplink-profile"
    EdgeUplinkProfile = "edge-uplink-profile"
    EdgeNamedTeaming  = "uplink-1-only"          # Used to pin BGP uplink VLAN to fp-eth0

    # --- 4. Transport zones ---
    OverlayTZ       = "tz-overlay"
    VlanTZ          = "tz-vlan-edge"

    # --- 5/6. Transport Node Profile ---
    TNP             = "tnp-lab-cluster-02"

    # --- 7. Edge node ---
    Edge = @{
        Name            = "nonfed-edge01"
        FQDN            = "nonfed-edge01.arkvcfimp.kodevirtual.com"
        FormFactor      = "MEDIUM"               # SMALL | MEDIUM | LARGE | XLARGE
        MgmtIP          = "172.21.10.85"
        MgmtPrefix      = 24
        MgmtGateway     = "172.21.10.1"
        MgmtPortGroup   = "DVPG-Mgmt"            # Existing port group for Edge management
        Datastore       = "NFS-DS-01"
        TrunkPortGroupA = "DVPG-Edge-Trunk-A"    # Created by script (VLAN trunk, dvUplink1 active)
        TrunkPortGroupB = "DVPG-Edge-Trunk-B"    # Created by script (VLAN trunk, dvUplink2 active)
        DNSServers      = @("172.16.101.9")
        NTPServers      = @("172.16.101.6")
        SearchDomains   = @("arkvcfimp.kodevirtual.com")
        EnableSSH       = $true
        AllowRootSSH    = $true
    }
    EdgeCluster     = "edge-cluster-01"

    # --- 8. BGP uplink VLAN segment ---
    UplinkSegment   = @{ Id = "seg-t0-uplink-2107"; VlanId = 2107 }

    # --- 9. Tier-0 ---
    T0 = @{
        Id          = "t0-gw01"
        HaMode      = "ACTIVE_STANDBY"
        UplinkIP    = "172.21.7.2"
        UplinkPrefix= 24
        UplinkMtu   = 1500
    }

    # --- 10. BGP ---
    Bgp = @{
        LocalAS      = "65001"
        NeighborIP   = "172.21.7.1"
        RemoteAS     = "65000"
        Password     = ""            # Optional MD5 password, leave empty for none
        KeepAlive    = 4
        HoldDown     = 12
    }

    # --- 11. Tier-1 ---
    T1Id            = "t1-gw01"

    # --- 12. Segments ---
    Segments = @(
        @{ Id = "seg-web"; Gateway = "10.10.10.1/24" }
        @{ Id = "seg-app"; Gateway = "10.10.20.1/24" }
        @{ Id = "seg-db";  Gateway = "10.10.30.1/24" }
    )
}

#endregion ===========================================================================

$ErrorActionPreference = "Stop"
$EP = "/policy/api/v1/infra/sites/default/enforcement-points/default"

function Write-Step  { param($Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param($Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }
function Write-Skip  { param($Msg) Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }
function Write-Warn2 { param($Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }

function ConvertTo-PlainText {
    param([SecureString]$Secure)
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Read-NsxPassword {
    param([string]$Name)
    while ($true) {
        $p1 = ConvertTo-PlainText (Read-Host "Enter $Name password" -AsSecureString)
        $p2 = ConvertTo-PlainText (Read-Host "Confirm $Name password" -AsSecureString)
        if ($p1 -ne $p2) { Write-Warn2 "Passwords do not match."; continue }
        if ($p1.Length -ge 12 -and $p1 -cmatch '[A-Z]' -and $p1 -cmatch '[a-z]' -and $p1 -match '\d' -and
            $p1 -match '[^a-zA-Z0-9]' -and ($p1.ToCharArray() | Sort-Object -Unique).Count -ge 5) { return $p1 }
        Write-Warn2 "Must be 12+ chars with upper, lower, digit, special and 5+ distinct characters."
    }
}

# ---------- NSX REST helper ----------
$script:IsPS7 = $PSVersionTable.PSVersion.Major -ge 7
if (-not $script:IsPS7) {
    Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllNsx : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; }
}
"@ -ErrorAction SilentlyContinue
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllNsx
    [System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12
}

function Invoke-Nsx {
    param([ValidateSet('GET','POST','PATCH','PUT','DELETE')][string]$Method, [string]$Path, $Body)
    $p = @{
        Uri         = "https://$($Config.NsxManager)$Path"
        Method      = $Method
        Headers     = $script:NsxHeaders
        ContentType = "application/json"
        TimeoutSec  = 120
    }
    if ($null -ne $Body) { $p.Body = ConvertTo-Json -InputObject $Body -Depth 30 }
    if ($script:IsPS7)   { $p.SkipCertificateCheck = $true }
    try { Invoke-RestMethod @p }
    catch {
        $detail = $_.ErrorDetails.Message
        throw "NSX API $Method $Path failed: $($_.Exception.Message)`n$detail"
    }
}

function Wait-Until {
    # Polls a scriptblock until it returns $true. The scriptblock may print progress.
    param([scriptblock]$Condition, [int]$TimeoutMin = 30, [int]$IntervalSec = 20, [string]$What)
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Condition) { return } }
        catch {
            if ($_.Exception.Message -like "FATAL:*") { throw }   # hard failure - stop immediately
            Write-Host "    ...$What not ready: $($_.Exception.Message.Split("`n")[0])"
        }
        Start-Sleep -Seconds $IntervalSec
    }
    throw "Timed out after $TimeoutMin min waiting for: $What"
}

function Get-MpId {
    # Returns the Manager-API UUID for a Policy-created object (needed by the MP edge API)
    param([string]$ListPath, [string]$DisplayName, [string]$IntentPath)
    for ($i = 0; $i -lt 12; $i++) {
        $m = (Invoke-Nsx GET $ListPath).results | Where-Object { $_.display_name -eq $DisplayName -or $_.id -eq $DisplayName } | Select-Object -First 1
        if ($m) { return $m.id }
        if ($IntentPath) {
            $r = Invoke-Nsx GET "/policy/api/v1/infra/realized-state/realized-entities?intent_path=$([uri]::EscapeDataString($IntentPath))"
            $id = ($r.results | Where-Object realization_specific_identifier | Select-Object -First 1).realization_specific_identifier
            if ($id) { return $id }
        }
        Start-Sleep -Seconds 10
    }
    throw "Could not find Manager ID for '$DisplayName' ($ListPath)"
}

function Get-SslThumbprint {
    param([string]$Server, [int]$Port = 443)
    $tcp = New-Object Net.Sockets.TcpClient($Server, $Port)
    try {
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ({ $true }))
        $ssl.AuthenticateAsClient($Server)
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($cert.RawData)
        ($hash | ForEach-Object { $_.ToString("X2") }) -join ":"
    } finally { $tcp.Close() }
}

#region ===================== CREDENTIALS & CONNECTIONS =====================

Write-Step "Collecting credentials"
$nsxCred  = Get-Credential -UserName $Config.NsxUser    -Message "NSX Manager credentials"
$vcCred   = Get-Credential -UserName $Config.vCenterUser -Message "vCenter credentials (also used for Compute Manager)"
$edgeAdminPwd = Read-NsxPassword -Name "Edge admin"
$edgeRootPwd  = Read-NsxPassword -Name "Edge root"
$edgeAuditPwd = Read-NsxPassword -Name "Edge audit"

$pair = "$($nsxCred.UserName):$($nsxCred.GetNetworkCredential().Password)"
$script:NsxHeaders = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair)) }

Write-Step "Connecting to NSX $($Config.NsxManager)"
$ver = Invoke-Nsx GET "/api/v1/node/version"
Write-Ok "NSX $($ver.product_version)"

Write-Step "Connecting to vCenter $($Config.vCenterServer) (PowerCLI)"
Import-Module VMware.VimAutomation.Core, VMware.VimAutomation.Vds | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Scope Session -Confirm:$false | Out-Null
$vc = Connect-VIServer -Server $Config.vCenterServer -Credential $vcCred
Write-Ok "Connected (vCenter $($vc.Version))"

#endregion

try {
    #region ===================== vCENTER PREP (PowerCLI) =====================

    Write-Step "Preparing vCenter objects"
    $cluster = Get-Cluster -Name $Config.Cluster
    $vds     = Get-VDSwitch -Name $Config.VDSwitch
    $vdsUuid = $vds.ExtensionData.Uuid
    $vdsUplinks = @($vds.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
    if ($vdsUplinks.Count -lt 2) { throw "$($vds.Name) needs at least 2 uplinks (found $($vdsUplinks.Count))." }
    Write-Ok "VDS $($vds.Name) v$($vds.Version), uplinks: $($vdsUplinks -join ', ')"

    if ($vds.Mtu -lt 1700) {
        Set-VDSwitch -VDSwitch $vds -Mtu $Config.VdsMtu -Confirm:$false | Out-Null
        Write-Ok "Raised VDS MTU $($vds.Mtu) -> $($Config.VdsMtu)"
    } else { Write-Skip "VDS MTU is $($vds.Mtu)" }

    # Edge trunk port groups (fp-eth0 -> A, fp-eth1 -> B)
    $trunkDefs = @(
        @{ Name = $Config.Edge.TrunkPortGroupA; Active = $vdsUplinks[0]; Standby = $vdsUplinks[1] }
        @{ Name = $Config.Edge.TrunkPortGroupB; Active = $vdsUplinks[1]; Standby = $vdsUplinks[0] }
    )
    $trunkPgs = @()
    foreach ($t in $trunkDefs) {
        $pg = Get-VDPortgroup -VDSwitch $vds -Name $t.Name -ErrorAction SilentlyContinue
        if (-not $pg) {
            $pg = New-VDPortgroup -VDSwitch $vds -Name $t.Name -VlanTrunkRange "0-4094" -NumPorts 8
            $pg | Get-VDUplinkTeamingPolicy |
                Set-VDUplinkTeamingPolicy -LoadBalancingPolicy ExplicitFailover `
                    -ActiveUplinkPort $t.Active -StandbyUplinkPort $t.Standby | Out-Null
            Write-Ok "Created trunk $($t.Name) (active $($t.Active))"
        } else { Write-Skip "Trunk $($t.Name) exists" }
        $trunkPgs += $pg
    }

    $edgeDs     = Get-Datastore -Name $Config.Edge.Datastore -RelatedObject $cluster
    $edgeMgmtPg = Get-VDPortgroup -Name $Config.Edge.MgmtPortGroup -ErrorAction SilentlyContinue
    if (-not $edgeMgmtPg) { $edgeMgmtPg = Get-VirtualPortGroup -VMHost (Get-VMHost -Location $cluster | Select-Object -First 1) -Name $Config.Edge.MgmtPortGroup -Standard }
    $moCluster = $cluster.ExtensionData.MoRef.Value
    $moDs      = $edgeDs.ExtensionData.MoRef.Value
    $moMgmt    = $edgeMgmtPg.ExtensionData.MoRef.Value
    $moTrunks  = @($trunkPgs | ForEach-Object { $_.ExtensionData.MoRef.Value })
    Write-Ok "MoRefs - cluster $moCluster, datastore $moDs, mgmt $moMgmt, trunks $($moTrunks -join ',')"

    #endregion

    #region ===================== 1. IP POOLS =====================

    Write-Step "1. IP pools (Host TEP / Edge TEP)"
    foreach ($pool in @($Config.HostTepPool, $Config.EdgeTepPool)) {
        Invoke-Nsx PATCH "/policy/api/v1/infra/ip-pools/$($pool.Id)" @{ display_name = $pool.Id } | Out-Null
        Invoke-Nsx PATCH "/policy/api/v1/infra/ip-pools/$($pool.Id)/ip-subnets/$($pool.Id)-subnet" @{
            resource_type     = "IpAddressPoolStaticSubnet"
            cidr              = $pool.Cidr
            gateway_ip        = $pool.Gateway
            allocation_ranges = @(@{ start = $pool.Start; end = $pool.End })
        } | Out-Null
        Write-Ok "$($pool.Id): $($pool.Start) - $($pool.End) ($($pool.Cidr), gw $($pool.Gateway))"
    }

    #endregion

    #region ===================== 2. COMPUTE MANAGER =====================

    Write-Step "2. Compute Manager $($Config.vCenterServer)"
    $cm = (Invoke-Nsx GET "/api/v1/fabric/compute-managers").results | Where-Object server -eq $Config.vCenterServer
    if (-not $cm) {
        $thumb = Get-SslThumbprint -Server $Config.vCenterServer
        Write-Ok "vCenter SHA-256 thumbprint: $thumb"
        $cm = Invoke-Nsx POST "/api/v1/fabric/compute-managers" @{
            display_name          = $Config.ComputeMgrName
            server                = $Config.vCenterServer
            origin_type           = "vCenter"
            set_as_oidc_provider  = $true
            create_service_account= $true
            access_level_for_oidc = "FULL"
            credential = @{
                credential_type = "UsernamePasswordLoginCredential"
                username        = $vcCred.UserName
                password        = $vcCred.GetNetworkCredential().Password
                thumbprint      = $thumb
            }
        }
        Write-Ok "Registered compute manager (id $($cm.id))"
    } else { Write-Skip "Already registered (id $($cm.id))" }
    $cmId = $cm.id

    Wait-Until -What "Compute Manager UP" -TimeoutMin 10 -IntervalSec 15 -Condition {
        $s = Invoke-Nsx GET "/api/v1/fabric/compute-managers/$cmId/status"
        Write-Host "    Connection: $($s.connection_status) | Registration: $($s.registration_status)"
        $s.connection_status -eq "UP" -and $s.registration_status -eq "REGISTERED"
    }
    Write-Ok "Compute Manager is UP and REGISTERED"

    #endregion

    #region ===================== 3. UPLINK PROFILES =====================

    Write-Step "3. Uplink profiles"
    Invoke-Nsx PATCH "/policy/api/v1/infra/host-switch-profiles/$($Config.HostUplinkProfile)" @{
        resource_type  = "PolicyUplinkHostSwitchProfile"
        display_name   = $Config.HostUplinkProfile
        transport_vlan = $Config.HostTepVlan
        teaming = @{
            policy      = "LOADBALANCE_SRCID"
            active_list = @(
                @{ uplink_name = "uplink-1"; uplink_type = "PNIC" }
                @{ uplink_name = "uplink-2"; uplink_type = "PNIC" })
        }
    } | Out-Null
    Write-Ok "$($Config.HostUplinkProfile) (TEP VLAN $($Config.HostTepVlan), multi-TEP)"

    Invoke-Nsx PATCH "/policy/api/v1/infra/host-switch-profiles/$($Config.EdgeUplinkProfile)" @{
        resource_type  = "PolicyUplinkHostSwitchProfile"
        display_name   = $Config.EdgeUplinkProfile
        transport_vlan = $Config.EdgeTepVlan
        teaming = @{
            policy      = "LOADBALANCE_SRCID"
            active_list = @(
                @{ uplink_name = "uplink-1"; uplink_type = "PNIC" }
                @{ uplink_name = "uplink-2"; uplink_type = "PNIC" })
        }
        named_teamings = @(
            @{
                name        = $Config.EdgeNamedTeaming
                policy      = "FAILOVER_ORDER"
                active_list = @(@{ uplink_name = "uplink-1"; uplink_type = "PNIC" })
            })
    } | Out-Null
    Write-Ok "$($Config.EdgeUplinkProfile) (TEP VLAN $($Config.EdgeTepVlan), named teaming $($Config.EdgeNamedTeaming))"

    #endregion

    #region ===================== 4. TRANSPORT ZONES =====================

    Write-Step "4. Transport zones"
    Invoke-Nsx PATCH "$EP/transport-zones/$($Config.OverlayTZ)" @{
        display_name = $Config.OverlayTZ; tz_type = "OVERLAY_BACKED"
    } | Out-Null
    Write-Ok "$($Config.OverlayTZ) (Overlay)"

    Invoke-Nsx PATCH "$EP/transport-zones/$($Config.VlanTZ)" @{
        display_name = $Config.VlanTZ; tz_type = "VLAN_BACKED"
        uplink_teaming_policy_names = @($Config.EdgeNamedTeaming)
    } | Out-Null
    Write-Ok "$($Config.VlanTZ) (VLAN, teaming $($Config.EdgeNamedTeaming))"

    $overlayTzPath = "/infra/sites/default/enforcement-points/default/transport-zones/$($Config.OverlayTZ)"
    $vlanTzPath    = "/infra/sites/default/enforcement-points/default/transport-zones/$($Config.VlanTZ)"

    #endregion

    #region ===================== 5. TRANSPORT NODE PROFILE =====================

    Write-Step "5. Transport Node Profile"
    Invoke-Nsx PUT "/policy/api/v1/infra/host-transport-node-profiles/$($Config.TNP)" @{
        display_name     = $Config.TNP
        host_switch_spec = @{
            resource_type = "StandardHostSwitchSpec"
            host_switches = @(@{
                host_switch_name         = $vds.Name
                host_switch_id           = $vdsUuid
                host_switch_type         = "VDS"
                host_switch_mode         = "STANDARD"
                host_switch_profile_ids  = @(@{ key = "UplinkHostSwitchProfile"; value = "/infra/host-switch-profiles/$($Config.HostUplinkProfile)" })
                uplinks                  = @(
                    @{ uplink_name = "uplink-1"; vds_uplink_name = $vdsUplinks[0] }
                    @{ uplink_name = "uplink-2"; vds_uplink_name = $vdsUplinks[1] })
                ip_assignment_spec       = @{ resource_type = "StaticIpPoolSpec"; ip_pool_id = "/infra/ip-pools/$($Config.HostTepPool.Id)" }
                transport_zone_endpoints = @(@{ transport_zone_id = $overlayTzPath })
            })
        }
    } | Out-Null
    Write-Ok "$($Config.TNP): $($vds.Name) [uplink-1=$($vdsUplinks[0]), uplink-2=$($vdsUplinks[1])], pool $($Config.HostTepPool.Id)"

    #endregion

    #region ===================== 6. APPLY TNP TO CLUSTER =====================

    Write-Step "6. Applying TNP to cluster $($Config.Cluster)"
    $cc = $null
    Wait-Until -What "cluster in NSX inventory" -TimeoutMin 5 -IntervalSec 15 -Condition {
        $script:cc = (Invoke-Nsx GET "/api/v1/fabric/compute-collections?origin_id=$cmId").results |
                     Where-Object display_name -eq $Config.Cluster | Select-Object -First 1
        [bool]$script:cc
    }
    $cc = $script:cc
    Write-Ok "Compute collection $($cc.external_id)"

    $tncId = "tnc-$($Config.Cluster.ToLower())"
    Invoke-Nsx PUT "$EP/transport-node-collections/$tncId" @{
        resource_type             = "HostTransportNodeCollection"
        display_name              = $tncId
        compute_collection_id     = $cc.external_id
        transport_node_profile_id = "/infra/host-transport-node-profiles/$($Config.TNP)"
    } | Out-Null
    Write-Ok "TNP attached - host preparation started"

    Wait-Until -What "host preparation" -TimeoutMin 45 -IntervalSec 30 -Condition {
        $s = Invoke-Nsx GET "$EP/transport-node-collections/$tncId/state"
        $pct = if ($s.aggregate_progress_percentage) { " ($($s.aggregate_progress_percentage)%)" } else { "" }
        Write-Host "    Cluster state: $($s.state)$pct"
        if ($s.state -like "FAILED*") { throw "FATAL: Host preparation failed: $(ConvertTo-Json $s -Depth 6)" }
        $s.state -eq "SUCCESS"
    }
    Write-Ok "All hosts in $($Config.Cluster) prepared"

    #endregion

    #region ===================== 7. EDGE NODE + EDGE CLUSTER =====================

    Write-Step "7. Edge node $($Config.Edge.Name)"
    $edge = (Invoke-Nsx GET "/api/v1/transport-nodes?node_types=EdgeNode").results | Where-Object display_name -eq $Config.Edge.Name
    if (-not $edge) {
        $mpEdgeProfile = Get-MpId "/api/v1/host-switch-profiles?hostswitch_profile_type=UplinkHostSwitchProfile" $Config.EdgeUplinkProfile "/infra/host-switch-profiles/$($Config.EdgeUplinkProfile)"
        $mpEdgePool    = Get-MpId "/api/v1/pools/ip-pools" $Config.EdgeTepPool.Id "/infra/ip-pools/$($Config.EdgeTepPool.Id)"
        $mpOverlayTz   = Get-MpId "/api/v1/transport-zones" $Config.OverlayTZ $overlayTzPath
        $mpVlanTz      = Get-MpId "/api/v1/transport-zones" $Config.VlanTZ $vlanTzPath
        Write-Ok "MP IDs resolved (profile, pool, overlay TZ, VLAN TZ)"

        $edge = Invoke-Nsx POST "/api/v1/transport-nodes" @{
            display_name = $Config.Edge.Name
            node_deployment_info = @{
                resource_type   = "EdgeNode"
                display_name    = $Config.Edge.Name
                ip_addresses    = @($Config.Edge.MgmtIP)
                deployment_type = "VIRTUAL_MACHINE"
                deployment_config = @{
                    form_factor = $Config.Edge.FormFactor
                    node_user_settings = @{
                        cli_username   = "admin";  cli_password   = $edgeAdminPwd
                        audit_username = "audit";  audit_password = $edgeAuditPwd
                        root_password  = $edgeRootPwd
                    }
                    vm_deployment_config = @{
                        placement_type            = "VsphereDeploymentConfig"
                        vc_id                     = $cmId
                        compute_id                = $moCluster
                        storage_id                = $moDs
                        management_network_id     = $moMgmt
                        management_port_subnets   = @(@{ ip_addresses = @($Config.Edge.MgmtIP); prefix_length = $Config.Edge.MgmtPrefix })
                        default_gateway_addresses = @($Config.Edge.MgmtGateway)
                        data_network_ids          = $moTrunks
                        reservation_info = @{
                            memory_reservation = @{ reservation_percentage = 0 }
                            cpu_reservation    = @{ reservation_in_shares = "LOW_PRIORITY"; reservation_in_mhz = 0 }
                        }
                    }
                }
                node_settings = @{
                    hostname             = $Config.Edge.FQDN
                    dns_servers          = $Config.Edge.DNSServers
                    ntp_servers          = $Config.Edge.NTPServers
                    search_domains       = $Config.Edge.SearchDomains
                    enable_ssh           = $Config.Edge.EnableSSH
                    allow_ssh_root_login = $Config.Edge.AllowRootSSH
                }
            }
            host_switch_spec = @{
                resource_type = "StandardHostSwitchSpec"
                host_switches = @(@{
                    host_switch_name         = "nsxHostSwitch"
                    host_switch_mode         = "STANDARD"
                    host_switch_profile_ids  = @(@{ key = "UplinkHostSwitchProfile"; value = $mpEdgeProfile })
                    pnics                    = @(
                        @{ device_name = "fp-eth0"; uplink_name = "uplink-1" }
                        @{ device_name = "fp-eth1"; uplink_name = "uplink-2" })
                    ip_assignment_spec       = @{ resource_type = "StaticIpPoolSpec"; ip_pool_id = $mpEdgePool }
                    transport_zone_endpoints = @(
                        @{ transport_zone_id = $mpOverlayTz }
                        @{ transport_zone_id = $mpVlanTz })
                })
            }
        }
        Write-Ok "Edge deployment started (id $($edge.id))"
    } else { Write-Skip "Edge exists (id $($edge.id))" }
    $edgeId = $edge.id

    Wait-Until -What "Edge deployment" -TimeoutMin 40 -IntervalSec 30 -Condition {
        $s = Invoke-Nsx GET "/api/v1/transport-nodes/$edgeId/state"
        Write-Host "    Edge state: $($s.state) | Deployment: $($s.node_deployment_state.state)"
        if ($s.state -eq "failed") { throw "FATAL: Edge failed: $(($s.failure_message, $s.node_deployment_state.failure_message) -join ' ')" }
        $s.state -eq "success"
    }
    Write-Ok "Edge $($Config.Edge.Name) is ready"

    Write-Step "7b. Edge cluster $($Config.EdgeCluster)"
    $ec = (Invoke-Nsx GET "/api/v1/edge-clusters").results | Where-Object display_name -eq $Config.EdgeCluster
    if (-not $ec) {
        $ec = Invoke-Nsx POST "/api/v1/edge-clusters" @{
            display_name = $Config.EdgeCluster
            members      = @(@{ transport_node_id = $edgeId })
        }
        Write-Ok "Created edge cluster (id $($ec.id))"
    } else { Write-Skip "Edge cluster exists (id $($ec.id))" }
    $ecPath = "/infra/sites/default/enforcement-points/default/edge-clusters/$($ec.id)"

    $edgeNodePath = $null
    Wait-Until -What "edge cluster visible in Policy" -TimeoutMin 5 -IntervalSec 10 -Condition {
        $n = (Invoke-Nsx GET "/policy/api$($ecPath -replace '^/infra','/v1/infra')/edge-nodes").results | Select-Object -First 1
        $script:edgeNodePath = $n.path
        [bool]$n
    }
    $edgeNodePath = $script:edgeNodePath
    Write-Ok "Edge node policy path: $edgeNodePath"

    #endregion

    #region ===================== 8. BGP UPLINK VLAN SEGMENT =====================

    Write-Step "8. BGP uplink VLAN segment"
    Invoke-Nsx PATCH "/policy/api/v1/infra/segments/$($Config.UplinkSegment.Id)" @{
        display_name        = $Config.UplinkSegment.Id
        vlan_ids            = @("$($Config.UplinkSegment.VlanId)")
        transport_zone_path = $vlanTzPath
        advanced_config     = @{ uplink_teaming_policy_name = $Config.EdgeNamedTeaming }
    } | Out-Null
    Write-Ok "$($Config.UplinkSegment.Id) (VLAN $($Config.UplinkSegment.VlanId), teaming $($Config.EdgeNamedTeaming))"

    #endregion

    #region ===================== 9. TIER-0 =====================

    Write-Step "9. Tier-0 $($Config.T0.Id)"
    $t0Base = "/policy/api/v1/infra/tier-0s/$($Config.T0.Id)"
    Invoke-Nsx PATCH $t0Base @{
        display_name  = $Config.T0.Id
        ha_mode       = $Config.T0.HaMode
        failover_mode = "NON_PREEMPTIVE"
    } | Out-Null
    Invoke-Nsx PATCH "$t0Base/locale-services/default" @{
        edge_cluster_path = $ecPath
        route_redistribution_config = @{
            bgp_enabled = $true
            redistribution_rules = @(@{
                name = "default-redist"
                route_redistribution_types = @("TIER0_CONNECTED", "TIER0_STATIC", "TIER1_CONNECTED", "TIER1_STATIC")
            })
        }
    } | Out-Null
    Invoke-Nsx PATCH "$t0Base/locale-services/default/interfaces/uplink-01" @{
        display_name = "uplink-01"
        type         = "EXTERNAL"
        segment_path = "/infra/segments/$($Config.UplinkSegment.Id)"
        edge_path    = $edgeNodePath
        subnets      = @(@{ ip_addresses = @($Config.T0.UplinkIP); prefix_len = $Config.T0.UplinkPrefix })
        mtu          = $Config.T0.UplinkMtu
    } | Out-Null
    Write-Ok "T0 created, uplink $($Config.T0.UplinkIP)/$($Config.T0.UplinkPrefix) on $($Config.Edge.Name), redistribution enabled"

    #endregion

    #region ===================== 10. BGP =====================

    Write-Step "10. BGP (AS $($Config.Bgp.LocalAS) <-> $($Config.Bgp.NeighborIP) AS $($Config.Bgp.RemoteAS))"
    Invoke-Nsx PATCH "$t0Base/locale-services/default/bgp" @{
        enabled      = $true
        local_as_num = $Config.Bgp.LocalAS
        ecmp         = $true
        graceful_restart_config = @{ mode = "HELPER_ONLY" }
    } | Out-Null

    $nbr = @{
        display_name     = "nbr-$($Config.Bgp.NeighborIP)"
        neighbor_address = $Config.Bgp.NeighborIP
        remote_as_num    = $Config.Bgp.RemoteAS
        keep_alive_time  = $Config.Bgp.KeepAlive
        hold_down_time   = $Config.Bgp.HoldDown
        source_addresses = @($Config.T0.UplinkIP)
    }
    if ($Config.Bgp.Password) { $nbr.password = $Config.Bgp.Password }
    $nbrId = "nbr-" + ($Config.Bgp.NeighborIP -replace '\.', '-')
    Invoke-Nsx PATCH "$t0Base/locale-services/default/bgp/neighbors/$nbrId" $nbr | Out-Null
    Write-Ok "BGP enabled, neighbor $($Config.Bgp.NeighborIP) configured"

    try {
        Wait-Until -What "BGP ESTABLISHED" -TimeoutMin 3 -IntervalSec 15 -Condition {
            $st = (Invoke-Nsx GET "$t0Base/locale-services/default/bgp/neighbors/status").results
            $states = ($st | ForEach-Object { "$($_.neighbor_address)=$($_.connection_state)" }) -join ', '
            Write-Host "    BGP: $states"
            @($st | Where-Object connection_state -eq "ESTABLISHED").Count -gt 0
        }
        Write-Ok "BGP session ESTABLISHED"
    } catch { Write-Warn2 "BGP not established yet - check the upstream router config (AS, IP, password, VLAN $($Config.UplinkSegment.VlanId))." }

    #endregion

    #region ===================== 11. TIER-1 =====================

    Write-Step "11. Tier-1 $($Config.T1Id)"
    Invoke-Nsx PATCH "/policy/api/v1/infra/tier-1s/$($Config.T1Id)" @{
        display_name              = $Config.T1Id
        tier0_path                = "/infra/tier-0s/$($Config.T0.Id)"
        failover_mode             = "NON_PREEMPTIVE"
        route_advertisement_types = @("TIER1_CONNECTED", "TIER1_STATIC_ROUTES")
    } | Out-Null
    Write-Ok "T1 linked to $($Config.T0.Id), advertising connected + static (distributed only)"

    #endregion

    #region ===================== 12. SEGMENTS =====================

    Write-Step "12. Overlay segments"
    foreach ($s in $Config.Segments) {
        Invoke-Nsx PATCH "/policy/api/v1/infra/segments/$($s.Id)" @{
            display_name        = $s.Id
            connectivity_path   = "/infra/tier-1s/$($Config.T1Id)"
            transport_zone_path = $overlayTzPath
            subnets             = @(@{ gateway_address = $s.Gateway })
        } | Out-Null
        Write-Ok "$($s.Id) - gateway $($s.Gateway)"
    }

    #endregion

    Write-Host "`n=====================================================" -ForegroundColor Green
    Write-Host " NSX configuration complete"                             -ForegroundColor Green
    Write-Host "  Hosts prepared : $($Config.Cluster) on $($vds.Name)"
    Write-Host "  Edge           : $($Config.Edge.Name) in $($Config.EdgeCluster)"
    Write-Host "  T0 / BGP       : $($Config.T0.Id)  AS $($Config.Bgp.LocalAS) -> $($Config.Bgp.NeighborIP)"
    Write-Host "  T1             : $($Config.T1Id)"
    Write-Host "  Segments       : $(($Config.Segments.Id) -join ', ')"
    Write-Host "=====================================================" -ForegroundColor Green
}
finally {
    $edgeAdminPwd = $edgeRootPwd = $edgeAuditPwd = $null
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}
