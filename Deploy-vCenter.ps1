<#
.SYNOPSIS
    Deploys a vCenter Server Appliance (VCSA 7.x / 8.x) from the mounted ISO using
    vcsa-deploy.exe, orchestrated with PowerShell + PowerCLI.

.DESCRIPTION
    1. Validates the ISO (H:\), DNS records and that the IP is free
    2. Uses PowerCLI to validate the target (cluster/host, datastore, port group, VM name)
       and auto-detects the datacenter
    3. Loads the matching JSON template FROM THE ISO (so the template version always matches
       the installer), fills in your values and writes a temporary JSON
    4. Runs vcsa-deploy: template verification -> precheck -> install
    5. Deletes the JSON (contains passwords) and verifies login to the new vCenter

    Supported targets:
      TargetType = "vCenter"  -> deploy onto a cluster managed by an existing vCenter
      TargetType = "ESXi"     -> deploy directly onto a standalone ESXi host

.NOTES
    - When deploying straight to ESXi onto a distributed port group, the port group must use
      EPHEMERAL binding. Deploying via an existing vCenter has no such restriction.
    - Stage 1 + Stage 2 together usually take 30-60 minutes.

.EXAMPLE
    .\Deploy-vCenter.ps1                 # full install
    .\Deploy-vCenter.ps1 -PrecheckOnly   # validate only, no deployment
#>

[CmdletBinding()]
param(
    [switch]$PrecheckOnly
)

#region ===================== CONFIGURATION - EDIT THIS SECTION =====================

$Config = @{
    # --- Installer ISO ---
    IsoDrive         = "H:"

    # --- Target to deploy ONTO ---
    TargetType       = "vCenter"                       # "vCenter" | "ESXi"
    TargetServer     = "vcsa01.kodevirtual.com"        # existing vCenter FQDN, or ESXi FQDN
    TargetUser       = "administrator@vsphere.local"   # "root" when TargetType = ESXi
    TargetCluster    = "Lab-Cluster"                   # vCenter target only
    Datastore        = "vsanDatastore"
    PortGroup        = "Nested-SA-Mgmt-2100"
    VMFolder         = ""                              # Optional, vCenter target only

    # --- New appliance ---
    VMName           = "nonfed-vc01"
    DeploymentSize   = "small"         # tiny | small | medium | large | xlarge (add -lstorage / -xlstorage)
    ThinDisk         = $true

    # --- New appliance networking ---
    FQDN             = "nonfed-vc01.arkvcfimp.kodevirtual.com"   # Must resolve forward + reverse
    IPAddress        = "172.21.10.80"
    PrefixLength     = "24"
    Gateway          = "172.21.10.1"
    DNSServers       = @("172.16.101.9")
    NTPServers       = "172.16.101.6"                  # Comma separated

    # --- SSO / OS ---
    SSODomain        = "vsphere.local"
    EnableSSH        = $true
    EnableCEIP       = $false
}

#endregion ===========================================================================

$ErrorActionPreference = "Stop"

function Write-Step  { param($Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param($Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }
function Write-Warn2 { param($Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }

function ConvertTo-PlainText {
    param([SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-ConfirmedPassword {
    param([string]$Name)
    while ($true) {
        $p1 = ConvertTo-PlainText (Read-Host "Enter $Name password" -AsSecureString)
        $p2 = ConvertTo-PlainText (Read-Host "Confirm $Name password" -AsSecureString)
        if ($p1 -ne $p2) { Write-Warn2 "Passwords do not match."; continue }
        # VCSA rules: 8-20 chars, upper, lower, digit, special
        if ($p1.Length -lt 8 -or $p1.Length -gt 20 -or $p1 -cnotmatch '[A-Z]' -or
            $p1 -cnotmatch '[a-z]' -or $p1 -notmatch '\d' -or $p1 -notmatch '[^a-zA-Z0-9]') {
            Write-Warn2 "$Name password must be 8-20 chars with upper, lower, digit and special character."
            continue
        }
        return $p1
    }
}

function Set-JsonProp {
    # Sets a property on a JSON-derived object, adding it if the template doesn't have it
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

#region ===================== PRE-CHECKS =====================

Write-Step "Checking installer ISO on $($Config.IsoDrive)"
$cliRoot     = Join-Path $Config.IsoDrive "vcsa-cli-installer"
$vcsaDeploy  = Join-Path $cliRoot "win32\vcsa-deploy.exe"
$templateDir = Join-Path $cliRoot "templates\install"
if (-not (Test-Path $vcsaDeploy)) { throw "vcsa-deploy.exe not found at $vcsaDeploy - is the VCSA ISO mounted on $($Config.IsoDrive)?" }

$templateName = if ($Config.TargetType -eq "vCenter") { "embedded_vCSA_on_VC.json" } else { "embedded_vCSA_on_ESXi.json" }
$templatePath = Join-Path $templateDir $templateName
if (-not (Test-Path $templatePath)) { throw "Template not found: $templatePath" }
$isoVersion = (Get-ChildItem $cliRoot -Filter "*.txt" -ErrorAction SilentlyContinue | Select-Object -First 1).Name
Write-Ok "Installer found, using template $templateName"

Write-Step "Checking DNS and IP"
try {
    $fwd = ([System.Net.Dns]::GetHostAddresses($Config.FQDN) | Where-Object AddressFamily -eq 'InterNetwork').IPAddressToString
    if ($fwd -notcontains $Config.IPAddress) { throw "Forward DNS for $($Config.FQDN) returns '$fwd', expected $($Config.IPAddress)" }
    Write-Ok "Forward DNS: $($Config.FQDN) -> $($Config.IPAddress)"
} catch { throw "Forward DNS check failed: $($_.Exception.Message). vCenter deployment fails without correct DNS." }
try {
    $rev = [System.Net.Dns]::GetHostEntry($Config.IPAddress).HostName
    if ($rev -ne $Config.FQDN) { Write-Warn2 "Reverse DNS returns $rev, expected $($Config.FQDN)" }
    else { Write-Ok "Reverse DNS: $($Config.IPAddress) -> $($Config.FQDN)" }
} catch { throw "Reverse DNS lookup failed for $($Config.IPAddress). Create the PTR record first." }

if ((New-Object System.Net.NetworkInformation.Ping).Send($Config.IPAddress, 1500).Status -eq 'Success') {
    throw "IP $($Config.IPAddress) already responds to ping - possible conflict."
}
Write-Ok "IP $($Config.IPAddress) is free"

Write-Step "Collecting credentials"
$targetCred   = Get-Credential -UserName $Config.TargetUser -Message "Credentials for target $($Config.TargetServer)"
$rootPassword = Read-ConfirmedPassword -Name "new vCenter root (appliance OS)"
$ssoPassword  = Read-ConfirmedPassword -Name "new vCenter SSO administrator@$($Config.SSODomain)"

#endregion

#region ===================== VALIDATE TARGET WITH POWERCLI =====================

Write-Step "Validating target $($Config.TargetServer) with PowerCLI"
Import-Module VMware.VimAutomation.Core | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Scope Session -Confirm:$false | Out-Null
$tgt = Connect-VIServer -Server $Config.TargetServer -Credential $targetCred
$datacenterName = $null
try {
    if (Get-VM -Name $Config.VMName -ErrorAction SilentlyContinue) { throw "VM '$($Config.VMName)' already exists on the target." }

    if ($Config.TargetType -eq "vCenter") {
        $cl = Get-Cluster -Name $Config.TargetCluster
        $datacenterName = (Get-Datacenter -Cluster $cl).Name
        Write-Ok "Cluster $($cl.Name) in datacenter $datacenterName"
        $ds = Get-Datastore -Name $Config.Datastore -RelatedObject $cl
        $pg = Get-VDPortgroup -Name $Config.PortGroup -ErrorAction SilentlyContinue
        if (-not $pg) { $pg = Get-VirtualPortGroup -VMHost (Get-VMHost -Location $cl | Select-Object -First 1) -Name $Config.PortGroup -Standard }
        if ($Config.VMFolder) { Get-Folder -Name $Config.VMFolder -Type VM | Out-Null }
    } else {
        $ds = Get-Datastore -Name $Config.Datastore
        $pg = Get-VirtualPortGroup -Name $Config.PortGroup
        if ($pg.ExtensionData.Config.Type -and $pg.ExtensionData.Config.Type -ne 'ephemeral') {
            Write-Warn2 "Port group is a distributed port group without ephemeral binding - ESXi-direct deployment will fail."
        }
    }
    Write-Ok "Datastore $($ds.Name) ($([math]::Round($ds.FreeSpaceGB)) GB free)"
    Write-Ok "Port group $($pg.Name)"
    if ($ds.FreeSpaceGB -lt 50) { Write-Warn2 "Low free space - thin disks start small but grow" }
}
finally { Disconnect-VIServer -Server $tgt -Confirm:$false -ErrorAction SilentlyContinue }

#endregion

#region ===================== BUILD JSON FROM ISO TEMPLATE =====================

Write-Step "Building deployment JSON from ISO template"
$json = Get-Content $templatePath -Raw | ConvertFrom-Json
$nv   = $json.new_vcsa

if ($Config.TargetType -eq "vCenter") {
    $t = $nv.vc
    Set-JsonProp $t hostname           $Config.TargetServer
    Set-JsonProp $t username           $Config.TargetUser
    Set-JsonProp $t password           $targetCred.GetNetworkCredential().Password
    Set-JsonProp $t deployment_network $Config.PortGroup
    Set-JsonProp $t datacenter         @($datacenterName)
    Set-JsonProp $t datastore          $Config.Datastore
    Set-JsonProp $t target             @($Config.TargetCluster)
    if ($Config.VMFolder) { Set-JsonProp $t vm_folder $Config.VMFolder }
} else {
    $t = $nv.esxi
    Set-JsonProp $t hostname           $Config.TargetServer
    Set-JsonProp $t username           $Config.TargetUser
    Set-JsonProp $t password           $targetCred.GetNetworkCredential().Password
    Set-JsonProp $t deployment_network $Config.PortGroup
    Set-JsonProp $t datastore          $Config.Datastore
}

Set-JsonProp $nv.appliance thin_disk_mode    $Config.ThinDisk
Set-JsonProp $nv.appliance deployment_option $Config.DeploymentSize
Set-JsonProp $nv.appliance name              $Config.VMName

Set-JsonProp $nv.network ip_family   "ipv4"
Set-JsonProp $nv.network mode        "static"
Set-JsonProp $nv.network system_name $Config.FQDN
Set-JsonProp $nv.network ip          $Config.IPAddress
Set-JsonProp $nv.network prefix      $Config.PrefixLength
Set-JsonProp $nv.network gateway     $Config.Gateway
Set-JsonProp $nv.network dns_servers @($Config.DNSServers)

Set-JsonProp $nv.os password    $rootPassword
Set-JsonProp $nv.os ntp_servers $Config.NTPServers
Set-JsonProp $nv.os ssh_enable  $Config.EnableSSH
if ($nv.os.PSObject.Properties.Name -contains 'time_tools_sync') { $nv.os.PSObject.Properties.Remove('time_tools_sync') }

Set-JsonProp $nv.sso password    $ssoPassword
Set-JsonProp $nv.sso domain_name $Config.SSODomain

Set-JsonProp $json.ceip.settings ceip_enabled $Config.EnableCEIP

$workDir  = Join-Path $env:TEMP "vcsa-deploy-$($Config.VMName)"
$logDir   = Join-Path $workDir "logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$jsonPath = Join-Path $workDir "$($Config.VMName).json"
$json | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding ASCII
Write-Ok "JSON written (temporary): $jsonPath"

#endregion

#region ===================== RUN VCSA-DEPLOY =====================

function Invoke-VcsaDeploy {
    param([string[]]$Arguments, [string]$Stage)
    Write-Step $Stage
    & $vcsaDeploy @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Stage failed (exit code $LASTEXITCODE). Logs: $logDir" }
    Write-Ok "$Stage passed"
}

try {
    $common = @("--accept-eula", "--no-ssl-certificate-verification", "--log-dir", $logDir)
    if ($Config.EnableCEIP) { $common += "--acknowledge-ceip" }

    Invoke-VcsaDeploy -Stage "Verifying template" -Arguments (@("install", "--verify-template-only") + $common + $jsonPath)
    Invoke-VcsaDeploy -Stage "Running prechecks"  -Arguments (@("install", "--precheck-only") + $common + $jsonPath)

    if ($PrecheckOnly) {
        Write-Host "`nPrecheck only - nothing deployed." -ForegroundColor Green
        return
    }

    Invoke-VcsaDeploy -Stage "Deploying vCenter (Stage 1 + Stage 2, 30-60 min)" -Arguments (@("install") + $common + $jsonPath)
}
finally {
    # JSON contains plaintext passwords - always remove it
    Remove-Item $jsonPath -Force -ErrorAction SilentlyContinue
    Write-Ok "Temporary JSON removed"
}

#endregion

#region ===================== VERIFY NEW VCENTER =====================

Write-Step "Verifying login to new vCenter $($Config.FQDN)"
try {
    $ssoCred = New-Object System.Management.Automation.PSCredential(
        "administrator@$($Config.SSODomain)", (ConvertTo-SecureString $ssoPassword -AsPlainText -Force))
    $newVc = Connect-VIServer -Server $Config.FQDN -Credential $ssoCred
    Write-Ok "Logged in - vCenter $($newVc.Version) build $($newVc.Build)"
    Disconnect-VIServer -Server $newVc -Confirm:$false
} catch { Write-Warn2 "Login check failed: $($_.Exception.Message). Services may still be starting - retry in a few minutes." }
finally { $rootPassword = $ssoPassword = $null }

Write-Host "`n=====================================================" -ForegroundColor Green
Write-Host " vCenter deployment complete"                            -ForegroundColor Green
Write-Host "  vSphere Client: https://$($Config.FQDN)/ui"
Write-Host "  VAMI:           https://$($Config.FQDN):5480"
Write-Host "  SSO user:       administrator@$($Config.SSODomain)"
Write-Host "  Logs:           $logDir"
Write-Host "=====================================================" -ForegroundColor Green

#endregion
