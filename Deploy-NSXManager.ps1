<#
.SYNOPSIS
    Deploys a single-node NSX Manager appliance (NSX-T 3.x / NSX 4.x) to vSphere using PowerCLI.

.DESCRIPTION
    - Validates inputs (password complexity, DNS, IP in use, OVA path)
    - Connects to vCenter and resolves cluster/host, datastore, port group, folder
    - Builds the OVF configuration (role, network, credentials, DNS/NTP, SSH)
    - Deploys the OVA (thin provisioned), powers on the VM
    - Waits for the NSX Manager API to report the management cluster as STABLE

.REQUIREMENTS
    - VMware PowerCLI 12.0+ (Install-Module VMware.PowerCLI -Scope CurrentUser)
    - NSX Manager OVA (e.g. nsx-unified-appliance-4.x.x.x.ova) accessible from this machine
    - Forward and reverse DNS records for the NSX Manager FQDN
    - Resources (Medium, recommended for production single node): 6 vCPU, 24 GB RAM, 300 GB disk
      Small: 4 vCPU / 16 GB (lab only)  |  Large: 12 vCPU / 48 GB

.EXAMPLE
    .\Deploy-NSXManager.ps1
    .\Deploy-NSXManager.ps1 -SkipWait
#>

[CmdletBinding()]
param(
    [switch]$SkipWait,              # Don't wait for NSX services to come up
    [int]$WaitTimeoutMinutes = 40   # Max time to wait for the API to be ready
)

#region ===================== CONFIGURATION - EDIT THIS SECTION =====================

$Config = @{
    # --- vCenter ---
    vCenterServer     = "vcenter01.lab.local"
    vCenterUser       = "administrator@vsphere.local"

    # --- OVA ---
    OvaPath           = "C:\ISO\nsx-unified-appliance-4.2.1.0.0.24304122.ova"

    # --- Placement ---
    Cluster           = "Mgmt-Cluster"         # Set either Cluster or VMHost
    VMHost            = ""                     # Optional: specific ESXi host
    Datastore         = "vsanDatastore"
    PortGroup         = "Mgmt-VDS-PG"          # VSS or VDS port group name
    VMFolder          = ""                     # Optional: VM folder name
    DiskFormat        = "Thin"                 # Thin | Thick | EagerZeroedThick

    # --- Appliance ---
    VMName            = "nsx-mgr-01"
    Hostname          = "nsx-mgr-01"           # Short hostname (FQDN = Hostname.Domain)
    Role              = "NSX Manager"          # "NSX Manager" | "NSX Global Manager"
    DeploymentSize    = "medium"               # extra_small | small | medium | large

    # --- Networking ---
    IPAddress         = "192.168.10.50"
    Netmask           = "255.255.255.0"
    Gateway           = "192.168.10.1"
    DNSServers        = "192.168.10.10,192.168.10.11"   # Comma separated
    DomainSearch      = "lab.local"
    NTPServers        = "192.168.10.10,pool.ntp.org"    # Comma separated

    # --- Users ---
    AdminUsername     = "admin"
    AuditUsername     = "audit"

    # --- SSH ---
    EnableSSH         = $true
    AllowRootSSH      = $false
}

#endregion ===========================================================================

$ErrorActionPreference = "Stop"

function Write-Step  { param($Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param($Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }
function Write-Warn2 { param($Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }

function ConvertTo-PlainText {
    param([SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Test-NsxPassword {
    # NSX policy: >=12 chars, upper, lower, digit, special, >=5 distinct chars
    param([string]$Pwd, [string]$Name)
    $errors = @()
    if ($Pwd.Length -lt 12)                         { $errors += "at least 12 characters" }
    if ($Pwd -cnotmatch '[A-Z]')                    { $errors += "an uppercase letter" }
    if ($Pwd -cnotmatch '[a-z]')                    { $errors += "a lowercase letter" }
    if ($Pwd -notmatch '\d')                        { $errors += "a digit" }
    if ($Pwd -notmatch '[^a-zA-Z0-9]')              { $errors += "a special character" }
    if (($Pwd.ToCharArray() | Sort-Object -Unique).Count -lt 5) { $errors += "at least 5 distinct characters" }
    if ($errors) { throw "$Name password must contain: $($errors -join ', ')" }
}

function Read-ConfirmedPassword {
    param([string]$Name)
    while ($true) {
        $p1 = ConvertTo-PlainText (Read-Host "Enter $Name password" -AsSecureString)
        $p2 = ConvertTo-PlainText (Read-Host "Confirm $Name password" -AsSecureString)
        if ($p1 -ne $p2) { Write-Warn2 "Passwords do not match, try again."; continue }
        try { Test-NsxPassword -Pwd $p1 -Name $Name; return $p1 }
        catch { Write-Warn2 $_.Exception.Message }
    }
}

function Set-OvfProp {
    # Sets an OVF property only if it exists in this OVA version
    param($Section, [string]$Name, $Value)
    if ($Section.PSObject.Properties.Name -contains $Name) {
        $Section.$Name.Value = $Value
    } else {
        Write-Warn2 "OVF property '$Name' not found in this OVA - skipped"
    }
}

#region ===================== PRE-CHECKS =====================

Write-Step "Running pre-checks"

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    throw "VMware PowerCLI not found. Install with: Install-Module VMware.PowerCLI -Scope CurrentUser"
}
Import-Module VMware.VimAutomation.Core | Out-Null
Write-Ok "PowerCLI loaded"

if (-not (Test-Path $Config.OvaPath)) { throw "OVA not found: $($Config.OvaPath)" }
Write-Ok "OVA found"

$fqdn = "$($Config.Hostname).$($Config.DomainSearch)"

# DNS forward / reverse
try {
    $fwd = [System.Net.Dns]::GetHostAddresses($fqdn) | Where-Object AddressFamily -eq 'InterNetwork'
    if ($fwd.IPAddressToString -notcontains $Config.IPAddress) {
        Write-Warn2 "Forward DNS for $fqdn resolves to $($fwd -join ',') - expected $($Config.IPAddress)"
    } else { Write-Ok "Forward DNS: $fqdn -> $($Config.IPAddress)" }
} catch { Write-Warn2 "Forward DNS lookup failed for $fqdn" }

try {
    $rev = [System.Net.Dns]::GetHostEntry($Config.IPAddress).HostName
    if ($rev -ne $fqdn) { Write-Warn2 "Reverse DNS for $($Config.IPAddress) returns $rev - expected $fqdn" }
    else { Write-Ok "Reverse DNS: $($Config.IPAddress) -> $fqdn" }
} catch { Write-Warn2 "Reverse DNS lookup failed for $($Config.IPAddress)" }

# IP conflict check
$ping = New-Object System.Net.NetworkInformation.Ping
if ($ping.Send($Config.IPAddress, 1500).Status -eq 'Success') {
    throw "IP $($Config.IPAddress) is already responding to ping - possible conflict."
}
Write-Ok "IP $($Config.IPAddress) is not in use"

# Passwords
Write-Step "Collecting credentials"
$vcCred        = Get-Credential -UserName $Config.vCenterUser -Message "vCenter credentials"
$rootPassword  = Read-ConfirmedPassword -Name "NSX root"
$adminPassword = Read-ConfirmedPassword -Name "NSX admin (CLI/UI)"
$auditPassword = Read-ConfirmedPassword -Name "NSX audit"

#endregion

#region ===================== CONNECT & RESOLVE INVENTORY =====================

Write-Step "Connecting to vCenter $($Config.vCenterServer)"
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
Set-PowerCLIConfiguration -ParticipateInCEIP $false -Scope Session -Confirm:$false | Out-Null
$vc = Connect-VIServer -Server $Config.vCenterServer -Credential $vcCred
Write-Ok "Connected to $($vc.Name) (vCenter $($vc.Version))"

try {
    if (Get-VM -Name $Config.VMName -ErrorAction SilentlyContinue) {
        throw "A VM named '$($Config.VMName)' already exists."
    }

    # Target host
    if ($Config.VMHost) {
        $vmHost = Get-VMHost -Name $Config.VMHost
    } else {
        $vmHost = Get-Cluster -Name $Config.Cluster | Get-VMHost |
                  Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' } |
                  Sort-Object MemoryUsageGB | Select-Object -First 1
    }
    if (-not $vmHost) { throw "No suitable connected ESXi host found." }
    Write-Ok "Target host: $($vmHost.Name)"

    $datastore = Get-Datastore -Name $Config.Datastore
    Write-Ok "Datastore: $($datastore.Name) ($([math]::Round($datastore.FreeSpaceGB)) GB free)"
    if ($datastore.FreeSpaceGB -lt 300) { Write-Warn2 "Less than 300 GB free - thick deployment may fail" }

    $portGroup = Get-VirtualPortGroup -VMHost $vmHost -Name $Config.PortGroup -ErrorAction SilentlyContinue
    if (-not $portGroup) { $portGroup = Get-VDPortgroup -Name $Config.PortGroup -ErrorAction Stop }
    Write-Ok "Port group: $($portGroup.Name)"

    $folder = $null
    if ($Config.VMFolder) { $folder = Get-Folder -Name $Config.VMFolder -Type VM; Write-Ok "Folder: $($folder.Name)" }

    #endregion

    #region ===================== BUILD OVF CONFIGURATION =====================

    Write-Step "Building OVF configuration"
    $ovfConfig = Get-OvfConfiguration -Ovf $Config.OvaPath

    # Deployment size
    $allowedSizes = $ovfConfig.DeploymentOption.AllowedValues
    if ($allowedSizes -notcontains $Config.DeploymentSize) {
        throw "Invalid DeploymentSize '$($Config.DeploymentSize)'. Allowed: $($allowedSizes -join ', ')"
    }
    $ovfConfig.DeploymentOption.Value = $Config.DeploymentSize
    Write-Ok "Size: $($Config.DeploymentSize)"

    # Network mapping (NSX OVA has a single network, name varies by version)
    foreach ($net in $ovfConfig.NetworkMapping.PSObject.Properties) {
        if ($net.Value -and $net.Value.PSObject.Properties.Name -contains 'Value') {
            $net.Value.Value = $portGroup.Name
            Write-Ok "Network '$($net.Name)' -> $($portGroup.Name)"
        }
    }

    # Disk provisioning (if exposed)
    if ($ovfConfig.PSObject.Properties.Name -contains 'IpAssignment' -and
        $ovfConfig.IpAssignment.PSObject.Properties.Name -contains 'IpProtocol') {
        $ovfConfig.IpAssignment.IpProtocol.Value = "IPv4"
    }

    $c = $ovfConfig.Common
    Set-OvfProp $c 'nsx_role'               $Config.Role
    Set-OvfProp $c 'nsx_hostname'           $Config.Hostname
    Set-OvfProp $c 'nsx_ip_0'               $Config.IPAddress
    Set-OvfProp $c 'nsx_netmask_0'          $Config.Netmask
    Set-OvfProp $c 'nsx_gateway_0'          $Config.Gateway
    Set-OvfProp $c 'nsx_dns1_0'             ($Config.DNSServers -replace ',', ' ')
    Set-OvfProp $c 'nsx_domain_0'           $Config.DomainSearch
    Set-OvfProp $c 'nsx_ntp_0'              ($Config.NTPServers -replace ',', ' ')
    Set-OvfProp $c 'nsx_isSSHEnabled'       $Config.EnableSSH
    Set-OvfProp $c 'nsx_allowSSHRootLogin'  $Config.AllowRootSSH
    Set-OvfProp $c 'nsx_passwd_0'           $rootPassword
    Set-OvfProp $c 'nsx_cli_username'       $Config.AdminUsername
    Set-OvfProp $c 'nsx_cli_passwd_0'       $adminPassword
    Set-OvfProp $c 'nsx_cli_audit_username' $Config.AuditUsername
    Set-OvfProp $c 'nsx_cli_audit_passwd_0' $auditPassword
    Write-Ok "OVF properties set"

    #endregion

    #region ===================== DEPLOY =====================

    Write-Step "Deploying $($Config.VMName) - this typically takes 10-20 minutes"
    $importParams = @{
        Source            = $Config.OvaPath
        OvfConfiguration  = $ovfConfig
        Name              = $Config.VMName
        VMHost            = $vmHost
        Datastore         = $datastore
        DiskStorageFormat = $Config.DiskFormat
        Confirm           = $false
    }
    if ($folder) { $importParams.InventoryLocation = $folder }

    $vm = Import-VApp @importParams
    Write-Ok "OVA imported: $($vm.Name)"

    Write-Step "Powering on $($vm.Name)"
    $vm = Start-VM -VM $vm -Confirm:$false
    Write-Ok "VM powered on"

    #endregion

    #region ===================== WAIT FOR NSX API =====================

    if (-not $SkipWait) {
        Write-Step "Waiting for NSX Manager services (timeout $WaitTimeoutMinutes min)"

        # Trust self-signed certs
        $isPS7 = $PSVersionTable.PSVersion.Major -ge 7
        if (-not $isPS7) {
            Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint s, X509Certificate c, WebRequest r, int p) { return true; }
}
"@ -ErrorAction SilentlyContinue
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        }

        $pair    = "$($Config.AdminUsername):$adminPassword"
        $headers = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)) }
        $uri     = "https://$($Config.IPAddress)/api/v1/cluster/status"
        $deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
        $ready = $false

        while ((Get-Date) -lt $deadline) {
            try {
                $rp = @{ Uri = $uri; Headers = $headers; Method = 'Get'; TimeoutSec = 15 }
                if ($isPS7) { $rp.SkipCertificateCheck = $true }
                $status = Invoke-RestMethod @rp
                $mgmt = $status.mgmt_cluster_status.status
                $ctrl = $status.control_cluster_status.status
                Write-Host "    Mgmt cluster: $mgmt | Control cluster: $ctrl"
                if ($mgmt -eq 'STABLE') { $ready = $true; break }
            } catch {
                Write-Host "    API not ready yet ($((Get-Date).ToString('HH:mm:ss')))..."
            }
            Start-Sleep -Seconds 30
        }

        if ($ready) { Write-Ok "NSX Manager is up and STABLE" }
        else { Write-Warn2 "Timed out waiting for STABLE status. Check the VM console / https://$($Config.IPAddress)" }
    }

    #endregion

    Write-Host "`n=====================================================" -ForegroundColor Green
    Write-Host " NSX Manager deployment complete"                       -ForegroundColor Green
    Write-Host "  UI:       https://$fqdn  (https://$($Config.IPAddress))"
    Write-Host "  Username: $($Config.AdminUsername)"
    Write-Host "  Size:     $($Config.DeploymentSize)"
    Write-Host " Next steps: accept EULA, add license, register vCenter"
    Write-Host "  as a Compute Manager, and take a backup config."
    Write-Host "=====================================================" -ForegroundColor Green
}
finally {
    # Clear plaintext passwords from memory
    $rootPassword = $adminPassword = $auditPassword = $null
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}
