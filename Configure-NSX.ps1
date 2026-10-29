<#
.SYNOPSIS
    End-to-end NSX 4.x configuration with PowerShell + PowerCLI.

    PowerCLI  -> vCenter lookups (VDS UUID/uplinks, MoRefs), VDS MTU, Edge trunk port groups
    NSX API   -> Policy API + MP API where Policy has no equivalent

    Steps
      0.  vCenter preparation (VDS MTU, Edge trunk port groups, MoRef lookups)
      1.  IP pools for Host TEP and Edge TEP
      2.  Add Compute Manager (vCenter) and wait for UP / REGISTERED
      3.  Uplink profiles (Host + Edge)
      4.  Transport Zones (Overlay + VLAN)
      5.  Transport Node Profile (VDS mode)
      6.  Apply TNP to the cluster and wait for SUCCESS
      7.  Deploy a single Edge node + single-member Edge Cluster (required by T0)
      8.  BGP uplink VLAN segment
      9.  Tier-0 gateway + uplink interface
      10. BGP + neighbor (waits for ESTABLISHED)
      11. Tier-1 gateway connected to T0
      12. Three overlay segments on T1

.BEHAVIOUR
    - EXISTING OBJECTS: every object is checked first, by ID and by display name. If it
      already exists it is SKIPPED (not modified) and the existing object is used by the
      following steps.
    - FAILURES: if any step fails the script STOPS immediately, prints the error and a
      summary of what was created / skipped up to that point. Fix the issue and re-run;
      completed objects will be skipped.

.NOTES
    - Host TEP VLAN and Edge TEP VLAN MUST be different when the Edge VM runs on hosts
      prepared on the same VDS (or route between them).
    - VDS MTU must be >= 1700 for Geneve; the script raises it to VdsMtu if lower.
    - API shape: NSX 4.1 / 4.2.
#>

[CmdletBinding()]
param()

#region ===================== CONFIGURATION - EDIT THIS SECTION =====================

$Config = @{
    # --- NSX Manager ---
    NsxManager      = "nonfed-nsx01.arkvcfimp.kodevirtual.com"
    NsxUser         = "admin"

    # --- vCenter (Compute Manager) ---
    vCenterServer   = "non-fed-vcsa01.arkvcfimp.kodevirtual.com"
    vCenterUser     = "administrator@vsphere.local"
    ComputeMgrName  = "non-fed-vcsa01.arkvcfimp.kodevirtual.com"

    # --- Host preparation ---
    Cluster         = "non-fed-cl01"            # Cluster to prepare with the TNP
    VDSwitch        = "vDS-01-Mgmt"             # VDS used for NSX (must be VDS 7.0+)
    VdsMtu          = 9000                      # Raised only if current MTU < 1700

    # --- 1. IP pools ---
    HostTepPool = @{ Id = "host-tep-pool"; Cidr = "172.21.13.0/24"; Gateway = "172.21.13.1"; Start = "172.21.13.110"; End = "172.21.13.120" }
    EdgeTepPool = @{ Id = "edge-tep-pool"; Cidr = "172.21.14.0/24"; Gateway = "172.21.14.1"; Start = "172.21.14.110"; End = "172.21.14.120" }

    # --- 3. Uplink profiles ---
    HostTepVlan       = 2103
    EdgeTepVlan       = 2104
    HostUplinkProfile = "host-uplink-profile"
    EdgeUplinkProfile = "edge-uplink-profile"
    EdgeNamedTeaming  = "uplink-1-only"         # Pins BGP uplink VLAN to fp-eth0

    # --- 4. Transport zones ---
    OverlayTZ       = "tz-overlay"
    VlanTZ          = "tz-vlan-edge"

    # --- 5/6. Transport Node Profile ---
    TNP             = "tnp-non-fed-cl01"

    # --- 7. Edge node ---
    Edge = @{
        Name            = "nonfed-edge01"
        FQDN            = "nonfed-edge01.arkvcfimp.kodevirtual.com"
        FormFactor      = "MEDIUM"               # SMALL | MEDIUM | LARGE | XLARGE
        MgmtIP          = "172.21.10.85"
        MgmtPrefix      = 24
        MgmtGateway     = "172.21.10.1"
        MgmtPortGroup   = "DVPG-Mgmt"
        Datastore       = "NFS-DS-01"
        TrunkPortGroupA = "DVPG-Edge-Trunk-A"    # Created by script (VLAN trunk, uplink 1 active)
        TrunkPortGroupB = "DVPG-Edge-Trunk-B"    # Created by script (VLAN trunk, uplink 2 active)
        DNSServers      = @("172.16.101.9")
        NTPServers      = @("172.16.101.6")
        SearchDomains   = @("arkvcfimp.kodevirtual.com")
        EnableSSH       = $true
        AllowRootSSH    = $true
    }
    EdgeCluster     = "edge-cluster-01"

    # --- 8. BGP uplink VLAN segment ---
    UplinkSegment   = @{ Id = "seg-t0-uplink-2105"; VlanId = 2105 }

    # --- 9. Tier-0 ---
    T0 = @{
        Id           = "t0-gw01"
        HaMode       = "ACTIVE_STANDBY"
        UplinkIP     = "172.21.15.20"
        UplinkPrefix = 24
        UplinkMtu    = 1500
    }

    # --- 10. BGP ---
    Bgp = @{
        LocalAS    = "65511"
        NeighborIP = "172.21.15.1"
        RemoteAS   = "65500"
        Password   = ""             # Optional MD5 password
        KeepAlive  = 4
        HoldDown   = 12
    }

    # --- 11. Tier-1 ---
    T1Id            = "t1-gw01"

    # --- 12. Segments ---
    Segments = @(
        @{ Id = "non-fed01-seg-web"; Gateway = "10.25.110.1/24" }
        @{ Id = "non-fed01-seg-app"; Gateway = "10.25.111.1/24" }
        @{ Id = "non-fed01-seg-db";  Gateway = "10.25.112.1/24" }
    )
}

#endregion ===========================================================================

$ErrorActionPreference = "Stop"
$EP      = "/policy/api/v1/infra/sites/default/enforcement-points/default"
$EPShort = "/infra/sites/default/enforcement-points/default"

#region ===================== OUTPUT & STEP TRACKING =====================

$script:Results     = New-Object System.Collections.Generic.List[object]
$script:StepCreated = 0
$script:StepSkipped = 0

function Write-Step  { param($Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param($Msg) $script:StepCreated++; Write-Host "    [CREATED] $Msg" -ForegroundColor Green }
function Write-Info  { param($Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }
function Write-Skip  { param($Msg) $script:StepSkipped++; Write-Host "    [SKIP] $Msg - already exists" -ForegroundColor DarkYellow }
function Write-Warn2 { param($Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }

function Show-Summary {
    Write-Host "`n==================== SUMMARY ====================" -ForegroundColor White
    $script:Results | Format-Table Step, Result -AutoSize | Out-String | Write-Host
}

function Invoke-Step {
    # Call with a leading dot ( . Invoke-Step ... ) so variables set inside the step
    # stay available to the following steps.
    param([string]$Name, [scriptblock]$Action)
    Write-Step $Name
    $script:StepCreated = 0; $script:StepSkipped = 0
    try {
        . $Action
    } catch {
        $script:Results.Add([pscustomobject]@{ Step = $Name; Result = "FAILED" })
        Write-Host "    [FAILED] $($_.Exception.Message)" -ForegroundColor Red
        Show-Summary
        Write-Host "Stopped at '$Name'. Fix the issue and re-run - completed objects will be skipped." -ForegroundColor Red
        throw "STEP_FAILED"
    }
    $r = if     ($script:StepCreated -eq 0 -and $script:StepSkipped -gt 0) { "Skipped (already exists)" }
         elseif ($script:StepCreated -gt 0 -and $script:StepSkipped -gt 0) { "Partially created ($($script:StepCreated) new, $($script:StepSkipped) existing)" }
         else   { "Completed" }
    $script:Results.Add([pscustomobject]@{ Step = $Name; Result = $r })
}

#endregion

#region ===================== HELPERS =====================

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
        throw "NSX API $Method $Path failed: $($_.Exception.Message) $detail"
    }
}

function Find-NsxObject {
    # Returns the first object in a list whose id OR display_name matches, else $null
    param([string]$ListPath, [string]$Name, [string]$Property = "display_name")
    $items = (Invoke-Nsx GET $ListPath).results
    $items | Where-Object { $_.id -eq $Name -or $_.$Property -eq $Name } | Select-Object -First 1
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutMin = 30, [int]$IntervalSec = 20, [string]$What)
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Condition) { return } }
        catch {
            if ($_.Exception.Message -like "FATAL:*") { throw }
            Write-Host "    ...$What not ready: $($_.Exception.Message.Split("`n")[0])"
        }
        Start-Sleep -Seconds $IntervalSec
    }
    throw "Timed out after $TimeoutMin min waiting for: $What"
}

function Get-MpId {
    # Manager-API UUID for a Policy object (the MP edge API needs these)
    param([string]$ListPath, [string]$DisplayName, [string]$IntentPath)
    for ($i = 0; $i -lt 12; $i++) {
        $m = (Invoke-Nsx GET $ListPath).results | Where-Object { $_.display_name -eq $DisplayName -or $_.id -eq $DisplayName } | Select-Object -First 1
        if ($m) { return $m.id }
        if ($IntentPath) {
            $r  = Invoke-Nsx GET "/policy/api/v1/infra/realized-state/realized-entities?intent_path=$([uri]::EscapeDataString($IntentPath))"
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

#endregion

#region ===================== CREDENTIALS & CONNECTIONS =====================

Write-Step "Collecting credentials"
$nsxCred      = Get-Credential -UserName $Config.NsxUser     -Message "NSX Manager credentials"
$vcCred       = Get-Credential -UserName $Config.vCenterUser -Message "vCenter credentials (also used for Compute Manager)"
$edgeAdminPwd = Read-NsxPassword -Name "Edge admin"
$edgeRootPwd  = Read-NsxPassword -Name "Edge root"
$edgeAuditPwd = Read-NsxPassword -Name "Edge audit"

$pair = "$($nsxCred.UserName):$($nsxCred.GetNetworkCredential().Password)"
$script:NsxHeaders = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair)) }

Write-Step "Connecting to NSX $($Config.NsxManager)"
$ver = Invoke-Nsx GET "/api/v1/node/version"
Write-Info "NSX $($ver.product_version)"

Write-Step "Connecting to vCenter $($Config.vCenterServer) (PowerCLI)"
Import-Module VMware.VimAutomation.Core, VMware.VimAutomation.Vds | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Scope Session -Confirm:$false | Out-Null
$vc = Connect-VIServer -Server $Config.vCenterServer -Credential $vcCred
Write-Info "Connected (vCenter $($vc.Version))"

#endregion

try {

    #region ===================== 0. vCENTER PREP =====================

    . Invoke-Step "0. vCenter preparation" {
        $cluster    = Get-Cluster -Name $Config.Cluster
        $vds        = Get-VDSwitch -Name $Config.VDSwitch
        $vdsUuid    = $vds.ExtensionData.Uuid
        $vdsUplinks = @($vds.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
        if ($vdsUplinks.Count -lt 2) { throw "$($vds.Name) needs at least 2 uplinks (found $($vdsUplinks.Count))." }
        Write-Info "VDS $($vds.Name) v$($vds.Version), uplinks: $($vdsUplinks -join ', ')"

        if ($vds.Mtu -lt 1700) {
            Set-VDSwitch -VDSwitch $vds -Mtu $Config.VdsMtu -Confirm:$false | Out-Null
            Write-Ok "VDS MTU raised $($vds.Mtu) -> $($Config.VdsMtu)"
        } else { Write-Skip "VDS MTU $($vds.Mtu) (>= 1700)" }

        $trunkDefs = @(
            @{ Name = $Config.Edge.TrunkPortGroupA; Active = $vdsUplinks[0]; Standby = $vdsUplinks[1] }
            @{ Name = $Config.Edge.TrunkPortGroupB; Active = $vdsUplinks[1]; Standby = $vdsUplinks[0] }
        )
        $trunkPgs = @()
        foreach ($t in $trunkDefs) {
            # Port group names are unique per datacenter, so search every VDS (not just this one)
            $pg = Get-VDPortgroup -Name $t.Name -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $pg) {
                $view = Get-View -ViewType DistributedVirtualPortgroup -Filter @{ Name = "^$([regex]::Escape($t.Name))$" } -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($view) { $pg = Get-VIObjectByVIView -VIView $view }
            }
            if ($pg) {
                $pgVds = $pg.VDSwitch.Name
                Write-Skip "Trunk port group $($t.Name) (on $pgVds)"
                if ($pgVds -and $pgVds -ne $vds.Name) {
                    Write-Warn2 "$($t.Name) is on $pgVds, not $($vds.Name) - it will be used for the Edge. Hosts in $($Config.Cluster) must be members of $pgVds."
                }
                $vlanCfg = $pg.ExtensionData.Config.DefaultPortConfig.Vlan
                if ($vlanCfg -and $vlanCfg.GetType().Name -ne "VmwareDistributedVirtualSwitchTrunkVlanSpec") {
                    Write-Warn2 "$($t.Name) is not a VLAN trunk - Edge TEP/uplink VLAN tagging will not work. Set it to trunk 0-4094."
                }
            }
            else {
                $pg = New-VDPortgroup -VDSwitch $vds -Name $t.Name -VlanTrunkRange "0-4094" -NumPorts 8
                $pg | Get-VDUplinkTeamingPolicy |
                    Set-VDUplinkTeamingPolicy -LoadBalancingPolicy ExplicitFailover `
                        -ActiveUplinkPort $t.Active -StandbyUplinkPort $t.Standby | Out-Null
                Write-Ok "Trunk port group $($t.Name) (active $($t.Active))"
            }
            $trunkPgs += $pg
        }

        $edgeDs     = Get-Datastore -Name $Config.Edge.Datastore -RelatedObject $cluster
        $edgeMgmtPg = Get-VDPortgroup -Name $Config.Edge.MgmtPortGroup -ErrorAction SilentlyContinue
        if (-not $edgeMgmtPg) {
            $edgeMgmtPg = Get-VirtualPortGroup -VMHost (Get-VMHost -Location $cluster | Select-Object -First 1) -Name $Config.Edge.MgmtPortGroup -Standard
        }
        $moCluster = $cluster.ExtensionData.MoRef.Value
        $moDs      = $edgeDs.ExtensionData.MoRef.Value
        $moMgmt    = $edgeMgmtPg.ExtensionData.MoRef.Value
        $moTrunks  = @($trunkPgs | ForEach-Object { $_.ExtensionData.MoRef.Value })
        Write-Info "MoRefs - cluster $moCluster, datastore $moDs, mgmt $moMgmt, trunks $($moTrunks -join ',')"
    }

    #endregion

    #region ===================== 1. IP POOLS =====================

    . Invoke-Step "1. IP pools (Host TEP / Edge TEP)" {
        $poolPaths = @{}
        foreach ($pool in @($Config.HostTepPool, $Config.EdgeTepPool)) {
            $existing = Find-NsxObject "/policy/api/v1/infra/ip-pools" $pool.Id
            if ($existing) {
                Write-Skip "IP pool $($pool.Id) (path $($existing.path))"
                $poolPaths[$pool.Id] = $existing.path
                $subnets = (Invoke-Nsx GET "/policy/api/v1$($existing.path)/ip-subnets").results
                if (-not $subnets) { Write-Warn2 "$($pool.Id) has no subnets - add a range manually or delete the pool and re-run" }
                continue
            }
            Invoke-Nsx PATCH "/policy/api/v1/infra/ip-pools/$($pool.Id)" @{ display_name = $pool.Id } | Out-Null
            Invoke-Nsx PATCH "/policy/api/v1/infra/ip-pools/$($pool.Id)/ip-subnets/$($pool.Id)-subnet" @{
                resource_type     = "IpAddressPoolStaticSubnet"
                cidr              = $pool.Cidr
                gateway_ip        = $pool.Gateway
                allocation_ranges = @(@{ start = $pool.Start; end = $pool.End })
            } | Out-Null
            $poolPaths[$pool.Id] = "/infra/ip-pools/$($pool.Id)"
            Write-Ok "IP pool $($pool.Id): $($pool.Start) - $($pool.End) ($($pool.Cidr), gw $($pool.Gateway))"
        }
        $hostPoolPath = $poolPaths[$Config.HostTepPool.Id]
        $edgePoolPath = $poolPaths[$Config.EdgeTepPool.Id]
        $edgePoolName = (Invoke-Nsx GET "/policy/api/v1$edgePoolPath").display_name
    }

    #endregion

    #region ===================== 2. COMPUTE MANAGER =====================

    . Invoke-Step "2. Compute Manager $($Config.vCenterServer)" {
        $cm = (Invoke-Nsx GET "/api/v1/fabric/compute-managers").results |
              Where-Object { $_.server -eq $Config.vCenterServer -or $_.display_name -eq $Config.ComputeMgrName } |
              Select-Object -First 1
        if ($cm) {
            Write-Skip "Compute manager $($cm.display_name) ($($cm.server))"
        } else {
            $thumb = Get-SslThumbprint -Server $Config.vCenterServer
            Write-Info "vCenter SHA-256 thumbprint: $thumb"
            $cm = Invoke-Nsx POST "/api/v1/fabric/compute-managers" @{
                display_name           = $Config.ComputeMgrName
                server                 = $Config.vCenterServer
                origin_type            = "vCenter"
                set_as_oidc_provider   = $true
                create_service_account = $true
                access_level_for_oidc  = "FULL"
                credential = @{
                    credential_type = "UsernamePasswordLoginCredential"
                    username        = $vcCred.UserName
                    password        = $vcCred.GetNetworkCredential().Password
                    thumbprint      = $thumb
                }
            }
            Write-Ok "Compute manager registered (id $($cm.id))"
        }
        $cmId = $cm.id

        Wait-Until -What "Compute Manager UP" -TimeoutMin 10 -IntervalSec 15 -Condition {
            $s = Invoke-Nsx GET "/api/v1/fabric/compute-managers/$cmId/status"
            Write-Host "    Connection: $($s.connection_status) | Registration: $($s.registration_status)"
            if ($s.connection_status -eq "DOWN" -and $s.registration_status -like "*FAILED*") {
                throw "FATAL: Compute manager registration failed ($($s.registration_status))"
            }
            $s.connection_status -eq "UP" -and $s.registration_status -eq "REGISTERED"
        }
        Write-Info "Compute Manager is UP and REGISTERED"
    }

    #endregion

    #region ===================== 3. UPLINK PROFILES =====================

    . Invoke-Step "3. Uplink profiles" {
        $hspList = "/policy/api/v1/infra/host-switch-profiles"

        $hp = Find-NsxObject $hspList $Config.HostUplinkProfile
        if ($hp) {
            Write-Skip "Host uplink profile $($hp.display_name)"
        } else {
            Invoke-Nsx PATCH "$hspList/$($Config.HostUplinkProfile)" @{
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
            $hp = Invoke-Nsx GET "$hspList/$($Config.HostUplinkProfile)"
            Write-Ok "Host uplink profile $($Config.HostUplinkProfile) (TEP VLAN $($Config.HostTepVlan))"
        }
        $hostProfilePath = $hp.path

        $edgeProf = Find-NsxObject $hspList $Config.EdgeUplinkProfile
        if ($edgeProf) {
            Write-Skip "Edge uplink profile $($edgeProf.display_name)"
            if ($edgeProf.named_teamings.name -notcontains $Config.EdgeNamedTeaming) {
                throw "Existing profile '$($edgeProf.display_name)' has no named teaming '$($Config.EdgeNamedTeaming)'. Add it or change EdgeNamedTeaming."
            }
        } else {
            Invoke-Nsx PATCH "$hspList/$($Config.EdgeUplinkProfile)" @{
                resource_type  = "PolicyUplinkHostSwitchProfile"
                display_name   = $Config.EdgeUplinkProfile
                transport_vlan = $Config.EdgeTepVlan
                teaming = @{
                    policy      = "LOADBALANCE_SRCID"
                    active_list = @(
                        @{ uplink_name = "uplink-1"; uplink_type = "PNIC" }
                        @{ uplink_name = "uplink-2"; uplink_type = "PNIC" })
                }
                named_teamings = @(@{
                    name        = $Config.EdgeNamedTeaming
                    policy      = "FAILOVER_ORDER"
                    active_list = @(@{ uplink_name = "uplink-1"; uplink_type = "PNIC" })
                })
            } | Out-Null
            $edgeProf = Invoke-Nsx GET "$hspList/$($Config.EdgeUplinkProfile)"
            Write-Ok "Edge uplink profile $($Config.EdgeUplinkProfile) (TEP VLAN $($Config.EdgeTepVlan), teaming $($Config.EdgeNamedTeaming))"
        }
        $edgeProfilePath = $edgeProf.path
        $edgeProfileName = $edgeProf.display_name
    }

    #endregion

    #region ===================== 4. TRANSPORT ZONES =====================

    . Invoke-Step "4. Transport zones" {
        $tzList = "$EP/transport-zones"

        $otz = Find-NsxObject $tzList $Config.OverlayTZ
        if ($otz) {
            if ($otz.tz_type -ne "OVERLAY_BACKED") { throw "'$($otz.display_name)' exists but is $($otz.tz_type), not OVERLAY_BACKED." }
            Write-Skip "Overlay TZ $($otz.display_name)"
        } else {
            Invoke-Nsx PATCH "$tzList/$($Config.OverlayTZ)" @{ display_name = $Config.OverlayTZ; tz_type = "OVERLAY_BACKED" } | Out-Null
            $otz = Invoke-Nsx GET "$tzList/$($Config.OverlayTZ)"
            Write-Ok "Overlay TZ $($Config.OverlayTZ)"
        }

        $vtz = Find-NsxObject $tzList $Config.VlanTZ
        if ($vtz) {
            if ($vtz.tz_type -ne "VLAN_BACKED") { throw "'$($vtz.display_name)' exists but is $($vtz.tz_type), not VLAN_BACKED." }
            Write-Skip "VLAN TZ $($vtz.display_name)"
            if ($vtz.uplink_teaming_policy_names -notcontains $Config.EdgeNamedTeaming) {
                Write-Warn2 "VLAN TZ does not list teaming '$($Config.EdgeNamedTeaming)' - uplink segment will use default teaming"
            }
        } else {
            Invoke-Nsx PATCH "$tzList/$($Config.VlanTZ)" @{
                display_name = $Config.VlanTZ; tz_type = "VLAN_BACKED"
                uplink_teaming_policy_names = @($Config.EdgeNamedTeaming)
            } | Out-Null
            $vtz = Invoke-Nsx GET "$tzList/$($Config.VlanTZ)"
            Write-Ok "VLAN TZ $($Config.VlanTZ) (teaming $($Config.EdgeNamedTeaming))"
        }
        $overlayTzPath = $otz.path
        $vlanTzPath    = $vtz.path
        $overlayTzName = $otz.display_name
        $vlanTzName    = $vtz.display_name
    }

    #endregion

    #region ===================== 5. TRANSPORT NODE PROFILE =====================

    . Invoke-Step "5. Transport Node Profile" {
        $tnpList = "/policy/api/v1/infra/host-transport-node-profiles"
        $tnp = Find-NsxObject $tnpList $Config.TNP
        if ($tnp) {
            Write-Skip "Transport Node Profile $($tnp.display_name)"
        } else {
            Invoke-Nsx PUT "$tnpList/$($Config.TNP)" @{
                display_name     = $Config.TNP
                host_switch_spec = @{
                    resource_type = "StandardHostSwitchSpec"
                    host_switches = @(@{
                        host_switch_name         = $vds.Name
                        host_switch_id           = $vdsUuid
                        host_switch_type         = "VDS"
                        host_switch_mode         = "STANDARD"
                        host_switch_profile_ids  = @(@{ key = "UplinkHostSwitchProfile"; value = $hostProfilePath })
                        uplinks                  = @(
                            @{ uplink_name = "uplink-1"; vds_uplink_name = $vdsUplinks[0] }
                            @{ uplink_name = "uplink-2"; vds_uplink_name = $vdsUplinks[1] })
                        ip_assignment_spec       = @{ resource_type = "StaticIpPoolSpec"; ip_pool_id = $hostPoolPath }
                        transport_zone_endpoints = @(@{ transport_zone_id = $overlayTzPath })
                    })
                }
            } | Out-Null
            $tnp = Invoke-Nsx GET "$tnpList/$($Config.TNP)"
            Write-Ok "Transport Node Profile $($Config.TNP) on $($vds.Name)"
        }
        $tnpPath = $tnp.path
    }

    #endregion

    #region ===================== 6. APPLY TNP TO CLUSTER =====================

    . Invoke-Step "6. Apply TNP to cluster $($Config.Cluster)" {
        Wait-Until -What "cluster in NSX inventory" -TimeoutMin 5 -IntervalSec 15 -Condition {
            $script:cc = (Invoke-Nsx GET "/api/v1/fabric/compute-collections?origin_id=$cmId").results |
                         Where-Object display_name -eq $Config.Cluster | Select-Object -First 1
            [bool]$script:cc
        }
        $cc = $script:cc
        Write-Info "Compute collection $($cc.external_id)"

        $tnc = (Invoke-Nsx GET "$EP/transport-node-collections").results |
               Where-Object compute_collection_id -eq $cc.external_id | Select-Object -First 1
        if ($tnc) {
            Write-Skip "TNP already applied to $($Config.Cluster) (collection $($tnc.id), profile $($tnc.transport_node_profile_id))"
            if ($tnc.transport_node_profile_id -ne $tnpPath) {
                Write-Warn2 "Cluster uses a different profile than $tnpPath - left unchanged"
            }
            $tncId = $tnc.id
        } else {
            $tncId = "tnc-$($Config.Cluster.ToLower())"
            Invoke-Nsx PUT "$EP/transport-node-collections/$tncId" @{
                resource_type             = "HostTransportNodeCollection"
                display_name              = $tncId
                compute_collection_id     = $cc.external_id
                transport_node_profile_id = $tnpPath
            } | Out-Null
            Write-Ok "TNP attached - host preparation started"
        }

        Wait-Until -What "host preparation" -TimeoutMin 45 -IntervalSec 30 -Condition {
            $s   = Invoke-Nsx GET "$EP/transport-node-collections/$tncId/state"
            $pct = if ($s.aggregate_progress_percentage) { " ($($s.aggregate_progress_percentage)%)" } else { "" }
            Write-Host "    Cluster state: $($s.state)$pct"
            if ($s.state -like "FAILED*") { throw "FATAL: Host preparation failed: $(ConvertTo-Json $s -Depth 6 -Compress)" }
            $s.state -eq "SUCCESS"
        }
        Write-Info "All hosts in $($Config.Cluster) prepared"
    }

    #endregion

    #region ===================== 7. EDGE NODE + EDGE CLUSTER =====================

    . Invoke-Step "7. Edge node $($Config.Edge.Name) + edge cluster" {
        $edge = (Invoke-Nsx GET "/api/v1/transport-nodes?node_types=EdgeNode").results |
                Where-Object display_name -eq $Config.Edge.Name | Select-Object -First 1
        if ($edge) {
            Write-Skip "Edge node $($edge.display_name) (id $($edge.id))"
        } else {
            if (Get-VM -Name $Config.Edge.Name -ErrorAction SilentlyContinue) {
                throw "A VM named '$($Config.Edge.Name)' exists in vCenter but is not an NSX Edge. Remove or rename it first."
            }
            $mpEdgeProfile = Get-MpId "/api/v1/host-switch-profiles?hostswitch_profile_type=UplinkHostSwitchProfile" $edgeProfileName $edgeProfilePath
            $mpEdgePool    = Get-MpId "/api/v1/pools/ip-pools" $edgePoolName $edgePoolPath
            $mpOverlayTz   = Get-MpId "/api/v1/transport-zones" $overlayTzName $overlayTzPath
            $mpVlanTz      = Get-MpId "/api/v1/transport-zones" $vlanTzName $vlanTzPath
            Write-Info "MP IDs resolved (profile, pool, overlay TZ, VLAN TZ)"

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
                            cli_username   = "admin"; cli_password   = $edgeAdminPwd
                            audit_username = "audit"; audit_password = $edgeAuditPwd
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
            Write-Ok "Edge node deployment started (id $($edge.id))"
        }
        $edgeId = $edge.id

        Wait-Until -What "Edge deployment" -TimeoutMin 40 -IntervalSec 30 -Condition {
            $s = Invoke-Nsx GET "/api/v1/transport-nodes/$edgeId/state"
            Write-Host "    Edge state: $($s.state) | Deployment: $($s.node_deployment_state.state)"
            if ($s.state -eq "failed") { throw "FATAL: Edge failed: $(($s.failure_message, $s.node_deployment_state.failure_message) -join ' ')" }
            $s.state -eq "success"
        }
        Write-Info "Edge $($Config.Edge.Name) is ready"

        # Edge cluster - reuse by name, or any edge cluster that already contains this edge
        $allEc = (Invoke-Nsx GET "/api/v1/edge-clusters").results
        $ec = $allEc | Where-Object { $_.display_name -eq $Config.EdgeCluster -or $_.members.transport_node_id -contains $edgeId } |
              Select-Object -First 1
        if ($ec) {
            Write-Skip "Edge cluster $($ec.display_name) (id $($ec.id))"
            if ($ec.members.transport_node_id -notcontains $edgeId) {
                throw "Edge cluster '$($ec.display_name)' exists but does not contain $($Config.Edge.Name). Add the edge to it or change EdgeCluster."
            }
        } else {
            $ec = Invoke-Nsx POST "/api/v1/edge-clusters" @{
                display_name = $Config.EdgeCluster
                members      = @(@{ transport_node_id = $edgeId })
            }
            Write-Ok "Edge cluster $($Config.EdgeCluster) (id $($ec.id))"
        }
        $ecPath = "$EPShort/edge-clusters/$($ec.id)"

        Wait-Until -What "edge cluster visible in Policy" -TimeoutMin 5 -IntervalSec 10 -Condition {
            $n = (Invoke-Nsx GET "$EP/edge-clusters/$($ec.id)/edge-nodes").results |
                 Where-Object { $_.nsx_id -eq $edgeId -or $_.display_name -eq $Config.Edge.Name } | Select-Object -First 1
            if (-not $n) { $n = (Invoke-Nsx GET "$EP/edge-clusters/$($ec.id)/edge-nodes").results | Select-Object -First 1 }
            $script:edgeNodePath = $n.path
            [bool]$n
        }
        $edgeNodePath = $script:edgeNodePath
        Write-Info "Edge node policy path: $edgeNodePath"
    }

    #endregion

    #region ===================== 8. BGP UPLINK VLAN SEGMENT =====================

    . Invoke-Step "8. BGP uplink VLAN segment" {
        $seg = Find-NsxObject "/policy/api/v1/infra/segments" $Config.UplinkSegment.Id
        if ($seg) {
            Write-Skip "Segment $($seg.display_name) (VLAN $($seg.vlan_ids -join ','))"
        } else {
            Invoke-Nsx PATCH "/policy/api/v1/infra/segments/$($Config.UplinkSegment.Id)" @{
                display_name        = $Config.UplinkSegment.Id
                vlan_ids            = @("$($Config.UplinkSegment.VlanId)")
                transport_zone_path = $vlanTzPath
                advanced_config     = @{ uplink_teaming_policy_name = $Config.EdgeNamedTeaming }
            } | Out-Null
            $seg = Invoke-Nsx GET "/policy/api/v1/infra/segments/$($Config.UplinkSegment.Id)"
            Write-Ok "Segment $($Config.UplinkSegment.Id) (VLAN $($Config.UplinkSegment.VlanId))"
        }
        $uplinkSegPath = $seg.path
    }

    #endregion

    #region ===================== 9. TIER-0 =====================

    . Invoke-Step "9. Tier-0 $($Config.T0.Id)" {
        $t0 = Find-NsxObject "/policy/api/v1/infra/tier-0s" $Config.T0.Id
        if ($t0) {
            Write-Skip "Tier-0 $($t0.display_name)"
        } else {
            Invoke-Nsx PATCH "/policy/api/v1/infra/tier-0s/$($Config.T0.Id)" @{
                display_name  = $Config.T0.Id
                ha_mode       = $Config.T0.HaMode
                failover_mode = "NON_PREEMPTIVE"
            } | Out-Null
            $t0 = Invoke-Nsx GET "/policy/api/v1/infra/tier-0s/$($Config.T0.Id)"
            Write-Ok "Tier-0 $($Config.T0.Id) ($($Config.T0.HaMode))"
        }
        $t0Path = $t0.path
        $t0Base = "/policy/api/v1$t0Path"

        # Locale services (edge cluster + redistribution)
        $ls = (Invoke-Nsx GET "$t0Base/locale-services").results | Select-Object -First 1
        if ($ls -and $ls.edge_cluster_path) {
            Write-Skip "Locale services $($ls.id) (edge cluster set)"
        } else {
            $lsId = if ($ls) { $ls.id } else { "default" }
            Invoke-Nsx PATCH "$t0Base/locale-services/$lsId" @{
                edge_cluster_path = $ecPath
                route_redistribution_config = @{
                    bgp_enabled = $true
                    redistribution_rules = @(@{
                        name = "default-redist"
                        route_redistribution_types = @("TIER0_CONNECTED", "TIER0_STATIC", "TIER1_CONNECTED", "TIER1_STATIC")
                    })
                }
            } | Out-Null
            $ls = Invoke-Nsx GET "$t0Base/locale-services/$lsId"
            Write-Ok "Locale services $lsId (edge cluster, route redistribution)"
        }
        $lsBase = "$t0Base/locale-services/$($ls.id)"

        # Uplink interface - skip if an interface already uses this IP or ID
        $ifs = (Invoke-Nsx GET "$lsBase/interfaces").results
        $if  = $ifs | Where-Object { $_.id -eq "uplink-01" -or $_.subnets.ip_addresses -contains $Config.T0.UplinkIP } | Select-Object -First 1
        if ($if) {
            Write-Skip "T0 interface $($if.id) ($($if.subnets.ip_addresses -join ','))"
        } else {
            Invoke-Nsx PATCH "$lsBase/interfaces/uplink-01" @{
                display_name = "uplink-01"
                type         = "EXTERNAL"
                segment_path = $uplinkSegPath
                edge_path    = $edgeNodePath
                subnets      = @(@{ ip_addresses = @($Config.T0.UplinkIP); prefix_len = $Config.T0.UplinkPrefix })
                mtu          = $Config.T0.UplinkMtu
            } | Out-Null
            Write-Ok "T0 interface uplink-01 $($Config.T0.UplinkIP)/$($Config.T0.UplinkPrefix)"
        }
    }

    #endregion

    #region ===================== 10. BGP =====================

    . Invoke-Step "10. BGP (AS $($Config.Bgp.LocalAS) -> $($Config.Bgp.NeighborIP) AS $($Config.Bgp.RemoteAS))" {
        $bgp = Invoke-Nsx GET "$lsBase/bgp"
        if ($bgp.enabled -and $bgp.local_as_num) {
            Write-Skip "BGP process (enabled, local AS $($bgp.local_as_num))"
            if ($bgp.local_as_num -ne $Config.Bgp.LocalAS) { Write-Warn2 "Existing local AS $($bgp.local_as_num) differs from config $($Config.Bgp.LocalAS) - left unchanged" }
        } else {
            Invoke-Nsx PATCH "$lsBase/bgp" @{
                enabled      = $true
                local_as_num = $Config.Bgp.LocalAS
                ecmp         = $true
                graceful_restart_config = @{ mode = "HELPER_ONLY" }
            } | Out-Null
            Write-Ok "BGP enabled (local AS $($Config.Bgp.LocalAS))"
        }

        $nbrs = (Invoke-Nsx GET "$lsBase/bgp/neighbors").results
        $n    = $nbrs | Where-Object neighbor_address -eq $Config.Bgp.NeighborIP | Select-Object -First 1
        if ($n) {
            Write-Skip "BGP neighbor $($Config.Bgp.NeighborIP) (remote AS $($n.remote_as_num))"
        } else {
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
            Invoke-Nsx PATCH "$lsBase/bgp/neighbors/$nbrId" $nbr | Out-Null
            Write-Ok "BGP neighbor $($Config.Bgp.NeighborIP) (remote AS $($Config.Bgp.RemoteAS))"
        }

        # Session state is informational - an upstream router issue should not stop the build
        try {
            Wait-Until -What "BGP ESTABLISHED" -TimeoutMin 3 -IntervalSec 15 -Condition {
                $st = (Invoke-Nsx GET "$lsBase/bgp/neighbors/status").results
                Write-Host "    BGP: $(($st | ForEach-Object { "$($_.neighbor_address)=$($_.connection_state)" }) -join ', ')"
                @($st | Where-Object { $_.neighbor_address -eq $Config.Bgp.NeighborIP -and $_.connection_state -eq "ESTABLISHED" }).Count -gt 0
            }
            Write-Info "BGP session ESTABLISHED"
        } catch {
            Write-Warn2 "BGP not ESTABLISHED yet - check upstream router (AS, IP, password, VLAN $($Config.UplinkSegment.VlanId)). Continuing."
        }
    }

    #endregion

    #region ===================== 11. TIER-1 =====================

    . Invoke-Step "11. Tier-1 $($Config.T1Id)" {
        $t1 = Find-NsxObject "/policy/api/v1/infra/tier-1s" $Config.T1Id
        if ($t1) {
            Write-Skip "Tier-1 $($t1.display_name)"
            if ($t1.tier0_path -ne $t0Path) { Write-Warn2 "Tier-1 is linked to '$($t1.tier0_path)', not $t0Path - left unchanged" }
        } else {
            Invoke-Nsx PATCH "/policy/api/v1/infra/tier-1s/$($Config.T1Id)" @{
                display_name              = $Config.T1Id
                tier0_path                = $t0Path
                failover_mode             = "NON_PREEMPTIVE"
                route_advertisement_types = @("TIER1_CONNECTED", "TIER1_STATIC_ROUTES")
            } | Out-Null
            $t1 = Invoke-Nsx GET "/policy/api/v1/infra/tier-1s/$($Config.T1Id)"
            Write-Ok "Tier-1 $($Config.T1Id) linked to $($Config.T0.Id)"
        }
        $t1Path = $t1.path
    }

    #endregion

    #region ===================== 12. SEGMENTS =====================

    . Invoke-Step "12. Overlay segments" {
        $allSegs = (Invoke-Nsx GET "/policy/api/v1/infra/segments").results
        foreach ($s in $Config.Segments) {
            $existing = $allSegs | Where-Object { $_.id -eq $s.Id -or $_.display_name -eq $s.Id } | Select-Object -First 1
            if (-not $existing) {
                # Also skip if another segment already owns this gateway
                $existing = $allSegs | Where-Object { $_.subnets.gateway_address -contains $s.Gateway } | Select-Object -First 1
            }
            if ($existing) {
                Write-Skip "Segment $($existing.display_name) ($($existing.subnets.gateway_address -join ','))"
                continue
            }
            Invoke-Nsx PATCH "/policy/api/v1/infra/segments/$($s.Id)" @{
                display_name        = $s.Id
                connectivity_path   = $t1Path
                transport_zone_path = $overlayTzPath
                subnets             = @(@{ gateway_address = $s.Gateway })
            } | Out-Null
            Write-Ok "Segment $($s.Id) - gateway $($s.Gateway)"
        }
    }

    #endregion

    Show-Summary
    Write-Host "NSX configuration complete." -ForegroundColor Green
}
catch {
    # Step failures already printed their error and summary; anything else lands here
    if ($_.Exception.Message -ne "STEP_FAILED") {
        Write-Host "`n[FAILED] $($_.Exception.Message)" -ForegroundColor Red
        Show-Summary
    }
    exit 1
}
finally {
    $edgeAdminPwd = $edgeRootPwd = $edgeAuditPwd = $null
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}
