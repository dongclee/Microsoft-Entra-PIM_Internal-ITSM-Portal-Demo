#requires -Version 5.1
<#
.SYNOPSIS
  Microsoft Entra PIM + Internal ITSM Financial Portal Launcher v2.0.5.1
.DESCRIPTION
  Builds and operates a customer-demonstration environment composed of:
  - A simple Internal Cloud Operations Portal on Azure App Service.
  - Microsoft Entra authentication through App Service Authentication (Easy Auth).
  - An Internal ITSM-style request, multi-approval, SoD, execution, expiry, revoke and evidence workflow.
  - Optional live Microsoft Entra PIM directory-role eligibility through the App Service managed identity.

  Safety model:
  1. Simulation is the default portal mode.
  2. Read-only inventory and WhatIf are performed before changes.
  3. Live PIM requires a separate, strongly confirmed managed-identity permission grant.
  4. The portal creates time-bound ELIGIBLE assignments; it does not create standing active assignments.
  5. PIM activation remains a user action governed by the role's PIM policy.
  6. Cleanup is restricted to objects tracked in the launcher state file.

.NOTES
  Reference design: Entra-PIM-ITSM-Financial-Launcher-v1.0 and its customer briefing.
  Target: Windows PowerShell 5.1 or PowerShell 7.x.
  Test in a non-production tenant/subscription first.
  Save and run this file as UTF-8 with BOM when using Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$Location = 'koreacentral',
    [string]$ResourceGroupName = 'rg-fin-pim-itsm-demo',
    [string]$AppServicePlanName = 'asp-fin-pim-itsm-demo',
    [string]$WebAppName,
    [ValidateSet('Simulation','Live')]
    [string]$PortalMode = 'Simulation',
    [string]$AssetPrefix = 'FIN-PIM-ITSM',
    [string]$DefaultRoleName = 'User Administrator',
    [int]$DefaultEligibilityDays = 30,
    [int]$DefaultActivationHours = 4,
    [string]$SampleUserUpn = '',
    [string]$ApproverAllowList = '',
    [int]$AuthSecretLifetimeDays = 7,
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'FIN-PIM-ITSM-Portal-Output'),
    [string]$StatePath = (Join-Path $PSScriptRoot 'FIN-PIM-ITSM-Portal-State.json')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:State = $null
$script:AzConnected = $false
$script:GraphConnected = $false
$script:TransientAuthSecret = $null
$script:LauncherVersion = '2.0.5.1'
$script:GraphServicePrincipalAppId = '00000003-0000-0000-c000-000000000000'
$script:PortalGraphAppRoles = @(
    'User.Read.All',
    'RoleManagement.Read.Directory',
    'RoleEligibilitySchedule.ReadWrite.Directory',
    'RoleManagementPolicy.Read.Directory',
    'AuditLog.Read.All'
)
$script:GraphDelegatedScopes = @(
    'User.Read.All',
    'RoleManagement.ReadWrite.Directory',
    'RoleEligibilitySchedule.ReadWrite.Directory',
    'RoleManagementPolicy.Read.Directory',
    'AuditLog.Read.All',
    'Application.ReadWrite.All',
    'AppRoleAssignment.ReadWrite.All',
    'Directory.Read.All'
)
$script:RequiredModules = @(
    [pscustomobject]@{ Name='Az.Accounts'; MinimumVersion='3.0.0' },
    [pscustomobject]@{ Name='Az.Resources'; MinimumVersion='7.0.0' },
    [pscustomobject]@{ Name='Az.Websites'; MinimumVersion='3.0.0' },
    [pscustomobject]@{ Name='Microsoft.Graph.Authentication'; MinimumVersion='2.0.0' }
)

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','STEP','OK','WARN','ERROR')][string]$Level = 'INFO'
    )
    $color = 'Cyan'
    if ($Level -eq 'STEP') { $color = 'White' }
    if ($Level -eq 'OK') { $color = 'Green' }
    if ($Level -eq 'WARN') { $color = 'Yellow' }
    if ($Level -eq 'ERROR') { $color = 'Red' }
    Write-Host ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message) -ForegroundColor $color
}

function Pause-Menu { [void](Read-Host 'Press Enter to continue') }
function Get-UtcNowText { (Get-Date).ToUniversalTime().ToString('o') }
function New-Id { ([guid]::NewGuid().Guid) }
function Ensure-Directory {
    param([string]$Path = $OutputRoot)
    if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -Path $Path -ItemType Directory -Force) }
}
function Get-PropertyValue {
    param($Object,[string]$Name,$Default=$null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function ConvertTo-SafeFileName {
    param([string]$Text)
    return (($Text -replace '[^a-zA-Z0-9._-]','-').Trim('-'))
}
function Confirm-ExactText {
    param([string]$Prompt,[string]$Expected)
    Write-Host $Prompt -ForegroundColor Yellow
    $actual = Read-Host ("Type exactly: {0}" -f $Expected)
    return ($actual -ceq $Expected)
}
function Assert-Name {
    param([string]$Value,[string]$Label,[string]$Pattern,[int]$Min,[int]$Max)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Label is empty." }
    if ($Value.Length -lt $Min -or $Value.Length -gt $Max -or $Value -notmatch $Pattern) {
        throw "$Label is invalid: $Value"
    }
}
function New-RandomText {
    param([int]$Bytes = 36)
    $buffer = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    return [Convert]::ToBase64String($buffer).Replace('+','A').Replace('/','B').Replace('=','')
}

function New-InitialState {
    [pscustomobject]@{
        Version = $script:LauncherVersion
        AssetPrefix = $AssetPrefix
        TenantId = $TenantId
        SubscriptionId = $SubscriptionId
        Location = $Location
        PortalMode = $PortalMode
        ResourceGroupName = $ResourceGroupName
        ResourceGroupCreatedByLauncher = $false
        AppServicePlanName = $AppServicePlanName
        WebAppName = $WebAppName
        WebAppHostName = $null
        WebAppResourceId = $null
        WebAppManagedIdentityObjectId = $null
        AuthApplicationObjectId = $null
        AuthApplicationClientId = $null
        AuthServicePrincipalObjectId = $null
        AuthSecretExpiresUtc = $null
        AuthIssuer = $null
        AuthMetadataUrl = $null
        AuthLastRepairUtc = $null
        GraphAppRoleAssignments = @()
        CreatedResources = @()
        LocalSourcePath = $null
        LocalPackagePath = $null
        WhatIfPlanPath = $null
        EvidenceFiles = @()
        LastDeploymentUtc = $null
        LastValidationUtc = $null
        LastUpdatedUtc = $null
    }
}

function Add-StatePropertyIfMissing {
    param([string]$Name,$Value)
    if ($null -eq $script:State.PSObject.Properties[$Name]) {
        $script:State | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Load-State {
    if (Test-Path -LiteralPath $StatePath) {
        $script:State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        foreach ($pair in @(
            @('Version',$script:LauncherVersion),@('AssetPrefix',$AssetPrefix),@('TenantId',$TenantId),@('SubscriptionId',$SubscriptionId),
            @('Location',$Location),@('PortalMode',$PortalMode),@('ResourceGroupName',$ResourceGroupName),@('ResourceGroupCreatedByLauncher',$false),
            @('AppServicePlanName',$AppServicePlanName),@('WebAppName',$WebAppName),@('WebAppHostName',$null),@('WebAppResourceId',$null),
            @('WebAppManagedIdentityObjectId',$null),@('AuthApplicationObjectId',$null),@('AuthApplicationClientId',$null),
            @('AuthServicePrincipalObjectId',$null),@('AuthSecretExpiresUtc',$null),@('AuthIssuer',$null),@('AuthMetadataUrl',$null),@('AuthLastRepairUtc',$null),@('GraphAppRoleAssignments',@()),@('CreatedResources',@()),
            @('LocalSourcePath',$null),@('LocalPackagePath',$null),@('WhatIfPlanPath',$null),@('EvidenceFiles',@()),
            @('LastDeploymentUtc',$null),@('LastValidationUtc',$null),@('LastUpdatedUtc',$null)
        )) { Add-StatePropertyIfMissing -Name $pair[0] -Value $pair[1] }
        Write-Log "State loaded: $StatePath" 'OK'
    } else {
        $script:State = New-InitialState
        Write-Log 'New launcher state initialized.' 'INFO'
    }
}

function Save-State {
    Ensure-Directory -Path (Split-Path -Parent $StatePath)
    $script:State.LastUpdatedUtc = Get-UtcNowText
    $json = $script:State | ConvertTo-Json -Depth 30
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($StatePath,$json,$utf8Bom)
    Write-Log "State saved: $StatePath" 'OK'
}

function Add-CreatedResource {
    param([string]$Type,[string]$Name,[string]$Id)
    $existing = @($script:State.CreatedResources | Where-Object { $_.Id -eq $Id })
    if ($existing.Count -eq 0) {
        $script:State.CreatedResources = @($script:State.CreatedResources) + @([pscustomobject]@{
            Type=$Type; Name=$Name; Id=$Id; CreatedUtc=Get-UtcNowText
        })
        Save-State
    }
}

function Assert-AzConnected {
    if (-not $script:AzConnected) {
        try {
            $ctx = Get-AzContext -ErrorAction Stop
            if ($null -eq $ctx -or [string]::IsNullOrWhiteSpace([string]$ctx.Subscription.Id)) { throw 'No context' }
            $script:AzConnected = $true
        } catch { throw 'Run menu 2 first to connect Azure.' }
    }
}
function Assert-GraphConnected {
    if (-not $script:GraphConnected) {
        try {
            $ctx = Get-MgContext -ErrorAction Stop
            if ($null -eq $ctx -or [string]::IsNullOrWhiteSpace([string]$ctx.TenantId)) { throw 'No context' }
            $script:GraphConnected = $true
        } catch { throw 'Run menu 2 first to connect Microsoft Graph.' }
    }
}
function Assert-Configuration {
    foreach ($n in @('TenantId','SubscriptionId','ResourceGroupName','AppServicePlanName','WebAppName')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $script:State $n ''))) { throw "Configuration is incomplete: $n" }
    }
}

function Invoke-Graph {
    param(
        [ValidateSet('GET','POST','PATCH','PUT','DELETE')][string]$Method,
        [Parameter(Mandatory=$true)][string]$Uri,
        $Body = $null
    )
    Assert-GraphConnected
    if ($Uri -notmatch '^https://') { $Uri = 'https://graph.microsoft.com/v1.0' + $Uri }
    $p = @{ Method=$Method; Uri=$Uri; OutputType='PSObject'; ErrorAction='Stop' }
    if ($null -ne $Body) {
        $p.Body = ($Body | ConvertTo-Json -Depth 30 -Compress)
        $p.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @p
}

function Get-AllGraphPages {
    param([Parameter(Mandatory=$true)][string]$Uri)
    $items = New-Object System.Collections.ArrayList
    $next = $Uri
    while ($next) {
        $r = Invoke-Graph -Method GET -Uri $next
        foreach ($i in @(Get-PropertyValue $r 'value' @())) { [void]$items.Add($i) }
        $next = Get-PropertyValue $r '@odata.nextLink' $null
    }
    return @($items)
}

function Invoke-Arm {
    param(
        [ValidateSet('GET','PUT','POST','PATCH','DELETE')][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        $Body = $null
    )
    Assert-AzConnected
    $p = @{ Method=$Method; Path=$Path; ErrorAction='Stop' }
    if ($null -ne $Body) { $p.Payload = ($Body | ConvertTo-Json -Depth 30 -Compress) }
    $result = Invoke-AzRestMethod @p
    if ($null -ne $result -and -not [string]::IsNullOrWhiteSpace([string]$result.Content)) {
        try { return ($result.Content | ConvertFrom-Json) } catch { return $result.Content }
    }
    return $result
}

function Test-Prerequisites {
    Write-Host ''
    Write-Host 'Menu P - Local prerequisite/module check' -ForegroundColor White
    $results = @()
    foreach ($required in $script:RequiredModules) {
        $m = Get-Module -ListAvailable -Name $required.Name | Sort-Object Version -Descending | Select-Object -First 1
        $ok = ($null -ne $m -and $m.Version -ge [version]$required.MinimumVersion)
        $results += [pscustomobject]@{
            Module=$required.Name; Minimum=$required.MinimumVersion; Installed=if($m){[string]$m.Version}else{'-'}; Ready=$ok
        }
    }
    $results | Format-Table -AutoSize
    $missing = @($results | Where-Object { -not $_.Ready })
    if ($missing.Count -eq 0) { Write-Log 'All required modules are ready.' 'OK'; return }
    if (-not (Confirm-ExactText -Prompt 'Missing/outdated modules can be installed for CurrentUser.' -Expected 'INSTALL-MODULES')) {
        Write-Log 'Module installation skipped.' 'WARN'; return
    }
    if ($PSVersionTable.PSVersion.Major -eq 5) { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
    foreach ($item in $missing) {
        Write-Log ("Installing {0} >= {1}" -f $item.Module,$item.Minimum) 'STEP'
        Install-Module -Name $item.Module -MinimumVersion $item.Minimum -Scope CurrentUser -Force -AllowClobber
    }
    Write-Log 'Module installation completed.' 'OK'
}

function Connect-DemoServices {
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Resources -ErrorAction Stop
    Import-Module Az.Websites -ErrorAction Stop
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    Write-Log 'Connecting to Azure...' 'STEP'
    $azParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $azParams.Tenant = $TenantId }
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) { $azParams.Subscription = $SubscriptionId }
    Connect-AzAccount @azParams | Out-Null
    $az = Get-AzContext
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { $script:State.SubscriptionId = [string]$az.Subscription.Id }
    else { Set-AzContext -SubscriptionId $SubscriptionId -TenantId $az.Tenant.Id | Out-Null; $script:State.SubscriptionId = $SubscriptionId }
    $script:State.TenantId = [string]$az.Tenant.Id
    $script:AzConnected = $true
    Write-Log ("Azure connected. Tenant={0}; Subscription={1}" -f $script:State.TenantId,$script:State.SubscriptionId) 'OK'

    Write-Log 'Connecting to Microsoft Graph with delegated setup scopes...' 'STEP'
    Connect-MgGraph -TenantId $script:State.TenantId -Scopes $script:GraphDelegatedScopes -NoWelcome
    $mg = Get-MgContext
    $script:GraphConnected = $true
    Write-Log ("Graph connected as {0}." -f $mg.Account) 'OK'
    Save-State
}

function Show-OperatingModel {
@'
===============================================================================
 Financial PIM + Internal ITSM Full Demo - Control and API Boundary
===============================================================================
1. Internal Portal owns the business request, ticket ID, business justification,
   system-owner approval, security approval and SoD decision.
2. Portal execution is blocked until the request is fully approved.
3. Live mode uses the App Service system-assigned managed identity and Microsoft
   Graph to create a time-bound ELIGIBLE directory-role assignment.
4. The target user activates the eligible role in Microsoft Entra PIM. MFA,
   justification, approver and maximum activation duration are PIM policy controls.
5. The portal tracks request, Graph request, target schedule, expiry/revoke and
   evidence. Local launcher state tracks the Azure/Entra deployment objects.
6. Cleanup removes only launcher-tracked Azure resources, authentication app and
   managed-identity Graph app-role assignments.

Boundary
- Microsoft Entra directory roles: Microsoft Graph roleManagement/directory.
- Azure subscription/resource roles: Azure Resource Manager PIM APIs; not included.
- Simulation mode: full portal workflow, no Graph write.
- Live mode: explicit app-role grant + Graph writes; use only in an approved lab.

Recommended demo flow
P -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8(optional Live) -> 9 -> 10 -> 11
Portal: Sample request -> approvals -> execute Eligible -> sync -> activation handoff
        -> expiry/revoke -> evidence ZIP
Cleanup: 90 preview -> 99 tracked full cleanup
'@ | Write-Host
}

function Set-DemoConfiguration {
    Write-Host ''
    Write-Host 'Menu 3 - Configure customer demo values' -ForegroundColor White
    $currentTenant = [string](Get-PropertyValue $script:State 'TenantId' $TenantId)
    $currentSub = [string](Get-PropertyValue $script:State 'SubscriptionId' $SubscriptionId)
    $currentRg = [string](Get-PropertyValue $script:State 'ResourceGroupName' $ResourceGroupName)
    $currentPlan = [string](Get-PropertyValue $script:State 'AppServicePlanName' $AppServicePlanName)
    $currentWeb = [string](Get-PropertyValue $script:State 'WebAppName' $WebAppName)
    if ([string]::IsNullOrWhiteSpace($currentWeb)) {
        $suffix = ((New-Id) -replace '-','').Substring(0,8)
        $currentWeb = ('fin-pim-itsm-{0}' -f $suffix).ToLowerInvariant()
    }
    $v = Read-Host "Tenant ID [$currentTenant]"; if (-not [string]::IsNullOrWhiteSpace($v)) { $currentTenant=$v }
    $v = Read-Host "Subscription ID [$currentSub]"; if (-not [string]::IsNullOrWhiteSpace($v)) { $currentSub=$v }
    $v = Read-Host "Azure location [$Location]"; if (-not [string]::IsNullOrWhiteSpace($v)) { $Location=$v }
    $v = Read-Host "Resource group [$currentRg]"; if (-not [string]::IsNullOrWhiteSpace($v)) { $currentRg=$v }
    $v = Read-Host "App Service plan [$currentPlan]"; if (-not [string]::IsNullOrWhiteSpace($v)) { $currentPlan=$v }
    $v = Read-Host "Globally unique Web App name [$currentWeb]"; if (-not [string]::IsNullOrWhiteSpace($v)) { $currentWeb=$v }
    $v = Read-Host "Portal mode Simulation or Live [$PortalMode]"; if (-not [string]::IsNullOrWhiteSpace($v)) { $PortalMode=$v }
    $v = Read-Host "Sample target UPN (optional) [$SampleUserUpn]"; if (-not [string]::IsNullOrWhiteSpace($v)) { $SampleUserUpn=$v }
    $v = Read-Host "Approver UPN allowlist, comma-separated; blank=any authenticated demo user [$ApproverAllowList]"; if (-not [string]::IsNullOrWhiteSpace($v)) { $ApproverAllowList=$v }

    if ($PortalMode -notin @('Simulation','Live')) { throw 'Portal mode must be Simulation or Live.' }
    Assert-Name -Value $currentRg -Label 'Resource group' -Pattern '^[a-zA-Z0-9._()\-]+$' -Min 1 -Max 90
    Assert-Name -Value $currentPlan -Label 'App Service plan' -Pattern '^[a-zA-Z0-9\-]+$' -Min 1 -Max 40
    Assert-Name -Value $currentWeb -Label 'Web App name' -Pattern '^[a-z0-9][a-z0-9\-]{1,58}[a-z0-9]$' -Min 3 -Max 60

    $script:State.TenantId=$currentTenant; $script:State.SubscriptionId=$currentSub; $script:State.Location=$Location
    $script:State.ResourceGroupName=$currentRg; $script:State.AppServicePlanName=$currentPlan; $script:State.WebAppName=$currentWeb
    $script:State.PortalMode=$PortalMode
    Save-State
    Write-Log ("Configured Web App: https://{0}.azurewebsites.net / Mode={1}" -f $currentWeb,$PortalMode) 'OK'
}

function Get-PortalSourceDirectory { Join-Path $OutputRoot 'PortalSource' }
function Get-PortalPackagePath { Join-Path $OutputRoot 'FIN-PIM-ITSM-Portal.zip' }

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$utf8)
}

function New-PortalSource {
    Ensure-Directory
    $source = Get-PortalSourceDirectory
    if (Test-Path -LiteralPath $source) { Remove-Item -LiteralPath $source -Recurse -Force }
    [void](New-Item -Path $source -ItemType Directory -Force)

    $appPy = @'
import csv
import hashlib
import io
import json
import os
import secrets
import sqlite3
import uuid
import zipfile
from datetime import datetime, timedelta, timezone
from functools import wraps
from urllib.parse import quote

import requests
from flask import Flask, Response, flash, redirect, render_template_string, request, send_file, session, url_for
from markupsafe import Markup
from werkzeug.exceptions import HTTPException

APP_VERSION = "2.0.5.1"
MODE = os.getenv("PIM_PORTAL_MODE", "Simulation")
DB_PATH = os.getenv("PIM_DB_PATH", "/home/data/pim-demo.db")
ROLE_ALLOWLIST = [x.strip() for x in os.getenv(
    "PIM_ROLE_ALLOWLIST",
    "User Administrator,Groups Administrator,Authentication Administrator,Helpdesk Administrator"
).split(",") if x.strip()]
APPROVER_ALLOWLIST = [x.strip().lower() for x in os.getenv("PIM_APPROVER_ALLOWLIST", "").split(",") if x.strip()]
SAMPLE_USER_UPN = os.getenv("PIM_SAMPLE_USER_UPN", "")
PORTAL_NAME = os.getenv("PIM_PORTAL_NAME", "Customer Cloud Operations Portal")
GRAPH_ROOT = "https://graph.microsoft.com/v1.0"
PIM_ACTIVATION_URL = "https://entra.microsoft.com/#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/aadRoles"

app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET_KEY", "demo-only-change-me")

BASE = r'''<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{ title }} | {{ portal_name }}</title>
<style>
:root{--navy:#08233f;--blue:#1267d6;--cyan:#12b7cf;--green:#16a085;--gold:#d6a52d;--red:#c84545;--bg:#f4f7fb;--ink:#102133;--muted:#637386;--line:#dce5ef;--card:#fff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);font-family:"Segoe UI",Arial,sans-serif;color:var(--ink)}
header{background:linear-gradient(105deg,var(--navy),#0d3d6d);color:#fff;padding:20px 32px;display:flex;justify-content:space-between;align-items:center;box-shadow:0 2px 14px #08233f33}
.brand{font-weight:750;font-size:20px}.sub{font-size:12px;color:#b9d7f6;margin-top:4px}.user{font-size:13px;text-align:right}
nav{background:#fff;border-bottom:1px solid var(--line);padding:0 26px;display:flex;gap:4px;overflow:auto}nav a{padding:14px 11px;color:#28425d;text-decoration:none;font-size:13px;font-weight:650;white-space:nowrap;border-bottom:3px solid transparent}nav a:hover{color:var(--blue);border-bottom-color:var(--cyan)}
main{max-width:1240px;margin:26px auto;padding:0 22px 50px}.title-row{display:flex;align-items:end;justify-content:space-between;margin-bottom:20px}h1{font-size:28px;margin:0}h2{font-size:20px;margin:0 0 14px}h3{font-size:15px;margin:0 0 8px}.hint{color:var(--muted);font-size:13px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:16px}.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;box-shadow:0 4px 14px #18385d0b}.metric{font-size:30px;font-weight:800;color:var(--blue);margin-top:7px}.accent{border-left:5px solid var(--cyan)}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid var(--line);border-radius:10px;overflow:hidden}th{background:#edf4fb;color:#27445f;font-size:12px;text-align:left;padding:11px}td{padding:11px;border-top:1px solid var(--line);font-size:13px;vertical-align:top}.mono{font-family:Consolas,monospace;font-size:12px;word-break:break-all}
.badge{display:inline-block;padding:4px 8px;border-radius:999px;font-size:11px;font-weight:750;background:#eaf1f8;color:#345}.b-ok{background:#dff6ed;color:#12684f}.b-warn{background:#fff0c9;color:#7a5610}.b-bad{background:#fde3e3;color:#8e2525}.b-info{background:#dbeaff;color:#164f9b}
.btn{display:inline-block;border:0;border-radius:7px;padding:9px 13px;background:var(--blue);color:#fff;text-decoration:none;font-size:12px;font-weight:700;cursor:pointer}.btn.alt{background:#49657f}.btn.good{background:var(--green)}.btn.warn{background:var(--gold);color:#17202a}.btn.danger{background:var(--red)}.btn.sm{padding:6px 9px}.actions{display:flex;gap:8px;flex-wrap:wrap}
label{display:block;font-size:12px;font-weight:700;color:#35516b;margin:12px 0 5px}input,select,textarea{width:100%;padding:10px;border:1px solid #cbd8e6;border-radius:7px;background:#fff;font:inherit}textarea{min-height:90px}.formgrid{display:grid;grid-template-columns:1fr 1fr;gap:0 18px}.wide{grid-column:1/-1}.flash{padding:12px 15px;border-radius:8px;margin-bottom:15px;background:#e0efff;color:#164f9b;border-left:4px solid var(--blue)}.warning{background:#fff5d8;color:#684d0b;border-left:5px solid var(--gold);padding:13px;border-radius:8px}.dangerbox{background:#ffeded;color:#7d2424;border-left:5px solid var(--red);padding:13px;border-radius:8px}.okbox{background:#e4f7f0;color:#105b48;border-left:5px solid var(--green);padding:13px;border-radius:8px}
.flow{display:grid;grid-template-columns:repeat(5,1fr);gap:9px;margin:18px 0}.step{background:#fff;border:1px solid var(--line);border-top:4px solid var(--blue);padding:14px 10px;border-radius:8px;text-align:center;font-size:12px;min-height:78px}.step strong{display:block;margin-bottom:5px}.footer{margin-top:32px;color:#7b8997;font-size:11px;border-top:1px solid var(--line);padding-top:14px}
pre{background:#0a2340;color:#d9eeff;border-radius:9px;padding:14px;overflow:auto;font-size:12px}@media(max-width:760px){header{padding:16px}.formgrid,.flow{grid-template-columns:1fr}.user{display:none}main{padding:0 12px}}
</style></head><body>
<header><div><div class="brand">{{ portal_name }}</div><div class="sub">Internal ITSM × Microsoft Entra PIM | Financial Demo</div></div><div class="user"><b>{{ actor }}</b><br>Mode: {{ mode }} · v{{ version }}</div></header>
<nav>
<a href="{{ url_for('dashboard') }}">Dashboard</a><a href="{{ url_for('new_request') }}">PIM 요청</a><a href="{{ url_for('requests_list') }}">요청 현황</a><a href="{{ url_for('approvals') }}">승인함</a><a href="{{ url_for('pim_assignments') }}">역할 할당</a><a href="{{ url_for('activation') }}">PIM 활성화</a><a href="{{ url_for('expiry') }}">만료·회수</a><a href="{{ url_for('audit') }}">감사·증적</a><a href="{{ url_for('settings') }}">설정</a>
</nav><main>
{% with messages = get_flashed_messages() %}{% for message in messages %}<div class="flash">{{ message }}</div>{% endfor %}{% endwith %}
{{ body }}
<div class="footer">Demo control: ITSM approval → Graph validation → time-bound Eligible → PIM activation policy → expiry/revoke → evidence. Azure Resource RBAC PIM is outside this sample.</div>
</main></body></html>'''


def now_utc():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_int(value, default, minimum, maximum):
    try:
        n = int(value)
    except Exception:
        n = default
    return min(max(n, minimum), maximum)


def actor():
    return (request.headers.get("X-MS-CLIENT-PRINCIPAL-NAME")
            or request.headers.get("X-MS-CLIENT-PRINCIPAL-ID")
            or "local-demo@contoso.com")


def can_approve():
    return not APPROVER_ALLOWLIST or actor().lower() in APPROVER_ALLOWLIST


def db():
    folder = os.path.dirname(DB_PATH)
    if folder:
        os.makedirs(folder, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db():
    with db() as c:
        c.executescript('''
        CREATE TABLE IF NOT EXISTS requests(
          id TEXT PRIMARY KEY, ticket_id TEXT UNIQUE NOT NULL, requester TEXT NOT NULL,
          requested_for_upn TEXT NOT NULL, role_name TEXT NOT NULL, scope_id TEXT NOT NULL DEFAULT '/',
          business_justification TEXT NOT NULL, eligibility_days INTEGER NOT NULL,
          activation_hours INTEGER NOT NULL, status TEXT NOT NULL, created_utc TEXT NOT NULL,
          updated_utc TEXT NOT NULL, executed_by TEXT, executed_utc TEXT,
          principal_id TEXT, role_definition_id TEXT, graph_request_id TEXT,
          target_schedule_id TEXT, graph_status TEXT, start_utc TEXT, end_utc TEXT,
          portal_owned INTEGER NOT NULL DEFAULT 0, last_error TEXT
        );
        CREATE TABLE IF NOT EXISTS approvals(
          id TEXT PRIMARY KEY, ticket_id TEXT NOT NULL, gate TEXT NOT NULL,
          decision TEXT NOT NULL, actor TEXT, comment TEXT, decided_utc TEXT,
          UNIQUE(ticket_id, gate)
        );
        CREATE TABLE IF NOT EXISTS events(
          id INTEGER PRIMARY KEY AUTOINCREMENT, ticket_id TEXT, event_type TEXT NOT NULL,
          actor TEXT NOT NULL, details TEXT, created_utc TEXT NOT NULL
        );
        ''')


def q(sql, args=(), one=False):
    with db() as c:
        cur = c.execute(sql, args)
        rows = cur.fetchall()
    return (rows[0] if rows else None) if one else rows


def execute(sql, args=()):
    with db() as c:
        c.execute(sql, args)


def log_event(ticket_id, event_type, details):
    execute("INSERT INTO events(ticket_id,event_type,actor,details,created_utc) VALUES(?,?,?,?,?)",
            (ticket_id, event_type, actor(), details, now_utc()))


def render_page(title, content_template, **ctx):
    content = render_template_string(content_template, **ctx)
    return render_template_string(BASE, title=title, body=Markup(content), portal_name=PORTAL_NAME,
                                  actor=actor(), mode=MODE, version=APP_VERSION)


def status_badge(value):
    v = value or "Unknown"
    css = "b-info"
    if v in ("Approved", "EligibleGranted", "Provisioned", "SimulatedEligible", "Revoked", "Passed"):
        css = "b-ok"
    elif v in ("Rejected", "Failed", "BlockedActiveAssignment"):
        css = "b-bad"
    elif v in ("PendingApproval", "ApprovedReady", "Provisioning", "Pending", "Expiring"):
        css = "b-warn"
    return Markup(f'<span class="badge {css}">{v}</span>')


app.jinja_env.globals["status_badge"] = status_badge


def csrf_token():
    if "_csrf" not in session:
        session["_csrf"] = secrets.token_urlsafe(32)
    return session["_csrf"]


app.jinja_env.globals["csrf_token"] = csrf_token


@app.before_request
def verify_csrf():
    if request.method == "POST":
        expected = session.get("_csrf", "")
        supplied = request.form.get("_csrf", "")
        if not expected or not supplied or not secrets.compare_digest(expected, supplied):
            return Response("CSRF validation failed",403)


init_db()


def create_ticket(upn, role, justification, days, hours, requested_by):
    ticket_id = "CHG-PIM-" + datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:4].upper()
    rid = str(uuid.uuid4())
    ts = now_utc()
    with db() as c:
        c.execute('''INSERT INTO requests(id,ticket_id,requester,requested_for_upn,role_name,business_justification,
                   eligibility_days,activation_hours,status,created_utc,updated_utc) VALUES(?,?,?,?,?,?,?,?,?,?,?)''',
                  (rid,ticket_id,requested_by,upn,role,justification,days,hours,"PendingApproval",ts,ts))
        for gate in ("SystemOwner","Security","SoD"):
            c.execute("INSERT INTO approvals(id,ticket_id,gate,decision) VALUES(?,?,?,?)",
                      (str(uuid.uuid4()),ticket_id,gate,"Pending"))
        c.execute("INSERT INTO events(ticket_id,event_type,actor,details,created_utc) VALUES(?,?,?,?,?)",
                  (ticket_id,"RequestCreated",requested_by,f"Role={role}; days={days}; activationHours={hours}",ts))
    return ticket_id


def recalc_request_status(ticket_id):
    approvals = q("SELECT decision FROM approvals WHERE ticket_id=?", (ticket_id,))
    decisions = [x["decision"] for x in approvals]
    if "Rejected" in decisions:
        status = "Rejected"
    elif len(decisions) == 3 and all(x == "Approved" for x in decisions):
        status = "ApprovedReady"
    else:
        status = "PendingApproval"
    execute("UPDATE requests SET status=?,updated_utc=? WHERE ticket_id=? AND status IN ('PendingApproval','ApprovedReady','Rejected')",
            (status,now_utc(),ticket_id))
    return status


def managed_identity_token():
    endpoint = os.getenv("IDENTITY_ENDPOINT")
    header = os.getenv("IDENTITY_HEADER")
    if not endpoint or not header:
        raise RuntimeError("Managed identity endpoint is unavailable. Run in Azure App Service with system-assigned identity.")
    r = requests.get(endpoint,
                     params={"api-version":"2019-08-01","resource":"https://graph.microsoft.com/"},
                     headers={"X-IDENTITY-HEADER":header}, timeout=20)
    if r.status_code >= 300:
        raise RuntimeError(f"Managed identity token failed: HTTP {r.status_code} {r.text[:500]}")
    return r.json()["access_token"]


def graph(method, path, params=None, body=None):
    token = managed_identity_token()
    r = requests.request(method, GRAPH_ROOT + path, params=params, json=body,
                         headers={"Authorization":"Bearer " + token,"Content-Type":"application/json"}, timeout=45)
    if r.status_code >= 300:
        raise RuntimeError(f"Graph {method} {path} failed: HTTP {r.status_code} {r.text[:900]}")
    if not r.content:
        return {}
    return r.json()


def graph_values(path, params=None):
    result = []
    url = GRAPH_ROOT + path
    token = managed_identity_token()
    while url:
        r = requests.get(url, params=params if not result else None,
                         headers={"Authorization":"Bearer " + token}, timeout=45)
        if r.status_code >= 300:
            raise RuntimeError(f"Graph GET {path} failed: HTTP {r.status_code} {r.text[:900]}")
        payload = r.json()
        result.extend(payload.get("value", []))
        url = payload.get("@odata.nextLink")
    return result


def resolve_user_and_role(row):
    upn = quote(row["requested_for_upn"], safe="")
    user = graph("GET", f"/users/{upn}", params={"$select":"id,displayName,userPrincipalName,accountEnabled"})
    if not user.get("accountEnabled", False):
        raise RuntimeError("Target user is disabled.")
    roles = graph_values("/roleManagement/directory/roleDefinitions",
                         params={"$filter":f"displayName eq '{row['role_name'].replace(chr(39), chr(39)*2)}'",
                                 "$select":"id,displayName,isBuiltIn"})
    exact = [x for x in roles if x.get("displayName") == row["role_name"]]
    if len(exact) != 1:
        raise RuntimeError("Role definition was not uniquely resolved.")
    return user, exact[0]


def find_duplicate_state(principal_id, role_definition_id):
    f = f"principalId eq '{principal_id}' and roleDefinitionId eq '{role_definition_id}'"
    active = graph_values("/roleManagement/directory/roleAssignmentScheduleInstances",
                          params={"$filter":f,"$select":"id,principalId,roleDefinitionId,startDateTime,endDateTime,assignmentType"})
    eligible = graph_values("/roleManagement/directory/roleEligibilityScheduleInstances",
                            params={"$filter":f,"$select":"id,principalId,roleDefinitionId,startDateTime,endDateTime,memberType"})
    requests_rows = graph_values("/roleManagement/directory/roleEligibilityScheduleRequests",
                                 params={"$filter":f,"$select":"id,status,action,targetScheduleId,createdDateTime"})
    pending = [x for x in requests_rows if x.get("status") in
               ("PendingApproval","PendingAdminDecision","PendingProvisioning","Provisioned")]
    return active, eligible, pending


@app.get("/health")
def health():
    return {"status":"ok","version":APP_VERSION,"mode":MODE,"database":"ready"}

@app.get("/route-manifest")
def route_manifest():
    routes=[]
    for rule in sorted(app.url_map.iter_rules(),key=lambda item:str(item)):
        if rule.endpoint != "static":
            routes.append({"path":str(rule),"endpoint":rule.endpoint,"methods":sorted(m for m in rule.methods if m not in ("HEAD","OPTIONS"))})
    return {"status":"ok","version":APP_VERSION,"routeCount":len(routes),"routes":routes}


@app.get("/")
def dashboard():
    counts = {r["status"]:r["n"] for r in q("SELECT status,COUNT(*) n FROM requests GROUP BY status")}
    total = sum(counts.values())
    recent = q("SELECT * FROM requests ORDER BY created_utc DESC LIMIT 6")
    return render_page("Dashboard", r'''
    <div class="title-row"><div><h1>Entra PIM 운영 Dashboard</h1><div class="hint">승인된 요청만 · 필요한 권한만 · 필요한 시간만</div></div><span class="badge b-info">{{ mode }} mode</span></div>
    {% if mode == 'Simulation' %}<div class="warning"><b>Simulation:</b> 포털의 전체 승인·만료·증적 흐름은 동작하지만 Microsoft Graph 변경은 수행하지 않습니다. Live 전환은 Launcher 메뉴 8의 별도 권한 승인 후 수행합니다.</div>{% else %}<div class="dangerbox"><b>LIVE PIM:</b> Execute/Revoke가 실제 Entra directory-role eligibility에 반영됩니다. 승인된 Lab tenant에서만 사용하십시오.</div>{% endif %}
    <div class="flow"><div class="step"><strong>1 · Request</strong>업무 사유·대상·기간</div><div class="step"><strong>2 · Approvals</strong>Owner·Security·SoD</div><div class="step"><strong>3 · Eligible</strong>Graph adminAssign</div><div class="step"><strong>4 · Activation</strong>PIM MFA·승인·사유</div><div class="step"><strong>5 · Expire</strong>자동 만료·긴급 회수</div></div>
    <div class="grid"><div class="card accent"><h3>Total requests</h3><div class="metric">{{ total }}</div></div><div class="card"><h3>승인 대기</h3><div class="metric">{{ counts.get('PendingApproval',0) }}</div></div><div class="card"><h3>실행 준비</h3><div class="metric">{{ counts.get('ApprovedReady',0) }}</div></div><div class="card"><h3>Eligible/Provisioned</h3><div class="metric">{{ counts.get('EligibleGranted',0)+counts.get('SimulatedEligible',0)+counts.get('Provisioning',0) }}</div></div></div>
    <h2 style="margin-top:26px">Recent requests</h2>
    <table><tr><th>Ticket</th><th>대상</th><th>Role</th><th>Status</th><th>Expiry</th></tr>{% for x in recent %}<tr><td><a href="{{ url_for('request_detail',ticket_id=x['ticket_id']) }}">{{ x['ticket_id'] }}</a></td><td>{{ x['requested_for_upn'] }}</td><td>{{ x['role_name'] }}</td><td>{{ status_badge(x['status']) }}</td><td>{{ x['end_utc'] or '-' }}</td></tr>{% else %}<tr><td colspan="5">요청이 없습니다. Sample request를 생성하십시오.</td></tr>{% endfor %}</table>
    <div class="actions" style="margin-top:14px"><a class="btn" href="{{ url_for('new_request') }}">새 PIM 요청</a><form method="post" action="{{ url_for('seed_sample') }}"><input type="hidden" name="_csrf" value="{{ csrf_token() }}"><button class="btn alt">Sample request 생성</button></form></div>
    ''', mode=MODE, total=total, counts=counts, recent=recent)


@app.route("/requests/new", methods=["GET","POST"])
def new_request():
    if request.method == "POST":
        upn = request.form.get("upn", "").strip()
        role = request.form.get("role", "").strip()
        justification = request.form.get("justification", "").strip()
        days = parse_int(request.form.get("days"),30,1,90)
        hours = parse_int(request.form.get("hours"),4,1,8)
        if "@" not in upn or role not in ROLE_ALLOWLIST or len(justification) < 10:
            flash("UPN, allowlisted role 및 10자 이상의 업무 사유를 확인하십시오.")
        else:
            ticket_id = create_ticket(upn,role,justification,days,hours,actor())
            flash(f"요청 {ticket_id} 생성 완료. 3개 승인 Gate를 진행하십시오.")
            return redirect(url_for("request_detail",ticket_id=ticket_id))
    return render_page("New PIM request", r'''
    <div class="title-row"><div><h1>Entra PIM 권한 요청</h1><div class="hint">Permanent Active가 아니라 기간 제한 Eligible 요청입니다.</div></div></div>
    <form class="card" method="post"><input type="hidden" name="_csrf" value="{{ csrf_token() }}"><div class="formgrid"><div><label>요청 대상 관리자 UPN</label><input name="upn" required value="{{ sample }}" placeholder="operator@contoso.com"></div><div><label>Entra directory role</label><select name="role">{% for r in roles %}<option>{{ r }}</option>{% endfor %}</select></div><div><label>Eligible 기간 (1~90일)</label><input type="number" name="days" value="30" min="1" max="90"></div><div><label>PIM 활성화 최대시간 요청값 (1~8시간)</label><input type="number" name="hours" value="4" min="1" max="8"></div><div class="wide"><label>업무 사유</label><textarea name="justification" required>승인된 사용자 관리 작업을 위한 기간 제한 Pilot 권한</textarea></div></div><div class="warning" style="margin:14px 0">Activation 시간은 요청 Context입니다. 실제 최대 활성화 시간·MFA·승인 요구 사항은 해당 Role의 Entra PIM 정책이 집행합니다.</div><button class="btn">ITSM 요청 제출</button></form>
    ''', roles=ROLE_ALLOWLIST, sample=SAMPLE_USER_UPN)


@app.post("/requests/seed")
def seed_sample():
    upn = SAMPLE_USER_UPN or actor()
    ticket_id = create_ticket(upn,ROLE_ALLOWLIST[0],"Customer demonstration for approved time-bound user administration",30,4,actor())
    flash(f"Sample request {ticket_id} created.")
    return redirect(url_for("request_detail",ticket_id=ticket_id))


@app.get("/requests")
def requests_list():
    rows = q("SELECT * FROM requests ORDER BY created_utc DESC")
    return render_page("Requests", r'''
    <div class="title-row"><div><h1>ITSM 요청 현황</h1><div class="hint">Ticket → approvals → Graph request → expiry를 하나의 레코드로 추적합니다.</div></div><a class="btn" href="{{ url_for('new_request') }}">New request</a></div>
    <table><tr><th>Ticket / Created</th><th>Requested for</th><th>Role / Duration</th><th>Status</th><th>Graph request</th></tr>{% for x in rows %}<tr><td><a href="{{ url_for('request_detail',ticket_id=x['ticket_id']) }}"><b>{{ x['ticket_id'] }}</b></a><br><span class="hint">{{ x['created_utc'] }}</span></td><td>{{ x['requested_for_upn'] }}</td><td>{{ x['role_name'] }}<br>{{ x['eligibility_days'] }}d Eligible / {{ x['activation_hours'] }}h activation</td><td>{{ status_badge(x['status']) }}</td><td class="mono">{{ x['graph_request_id'] or '-' }}</td></tr>{% else %}<tr><td colspan="5">No requests</td></tr>{% endfor %}</table>
    ''', rows=rows)


@app.get("/requests/<ticket_id>")
def request_detail(ticket_id):
    row = q("SELECT * FROM requests WHERE ticket_id=?",(ticket_id,),one=True)
    if not row: return Response("Not found",404)
    gates = q("SELECT * FROM approvals WHERE ticket_id=? ORDER BY CASE gate WHEN 'SystemOwner' THEN 1 WHEN 'Security' THEN 2 ELSE 3 END",(ticket_id,))
    events = q("SELECT * FROM events WHERE ticket_id=? ORDER BY id DESC",(ticket_id,))
    return render_page(ticket_id, r'''
    <div class="title-row"><div><h1>{{ row['ticket_id'] }}</h1><div class="hint">{{ row['requested_for_upn'] }} · {{ row['role_name'] }}</div></div>{{ status_badge(row['status']) }}</div>
    {% if row['last_error'] %}<div class="dangerbox"><b>Last error</b><br>{{ row['last_error'] }}</div>{% endif %}
    <div class="grid"><div class="card"><h3>Request</h3><b>{{ row['business_justification'] }}</b><p class="hint">Requester: {{ row['requester'] }}<br>Created: {{ row['created_utc'] }}</p></div><div class="card"><h3>Time boundary</h3><div class="metric">{{ row['eligibility_days'] }}d</div><div class="hint">PIM activation request: max {{ row['activation_hours'] }}h</div></div><div class="card"><h3>Graph correlation</h3><div class="mono">Request: {{ row['graph_request_id'] or '-' }}<br>Schedule: {{ row['target_schedule_id'] or '-' }}</div></div></div>
    <h2 style="margin-top:24px">Approval gates</h2><div class="grid">{% for g in gates %}<div class="card"><h3>{{ g['gate'] }}</h3>{{ status_badge(g['decision']) }}<p class="hint">{{ g['actor'] or '-' }}<br>{{ g['decided_utc'] or '-' }}<br>{{ g['comment'] or '' }}</p>{% if g['decision']=='Pending' and can_approve %}<form method="post" action="{{ url_for('decide_gate',ticket_id=row['ticket_id'],gate=g['gate']) }}"><input type="hidden" name="_csrf" value="{{ csrf_token() }}"><input name="comment" placeholder="Approval comment"><div class="actions" style="margin-top:8px"><button class="btn good sm" name="decision" value="Approved">Approve</button><button class="btn danger sm" name="decision" value="Rejected">Reject</button></div></form>{% endif %}</div>{% endfor %}</div>
    <div class="actions" style="margin-top:20px">{% if row['status']=='ApprovedReady' and can_approve %}<form method="post" action="{{ url_for('execute_pim',ticket_id=row['ticket_id']) }}"><input type="hidden" name="_csrf" value="{{ csrf_token() }}"><button class="btn good">Eligible 실행</button></form>{% endif %}{% if row['graph_request_id'] and can_approve %}<form method="post" action="{{ url_for('sync_request',ticket_id=row['ticket_id']) }}"><input type="hidden" name="_csrf" value="{{ csrf_token() }}"><button class="btn alt">Graph 상태 Sync</button></form>{% endif %}{% if row['target_schedule_id'] and row['portal_owned'] and can_approve %}<form method="post" action="{{ url_for('revoke',ticket_id=row['ticket_id']) }}"><input type="hidden" name="_csrf" value="{{ csrf_token() }}"><input type="hidden" name="confirm" value="{{ row['ticket_id'] }}"><button class="btn danger">Tracked eligibility 회수</button></form>{% endif %}</div>
    <h2 style="margin-top:24px">Audit trail</h2><table><tr><th>UTC</th><th>Actor</th><th>Event</th><th>Details</th></tr>{% for e in events %}<tr><td>{{ e['created_utc'] }}</td><td>{{ e['actor'] }}</td><td>{{ e['event_type'] }}</td><td>{{ e['details'] }}</td></tr>{% endfor %}</table>
    ''', row=row, gates=gates, events=events, can_approve=can_approve())


@app.post("/requests/<ticket_id>/gate/<gate>")
def decide_gate(ticket_id, gate):
    if gate not in ("SystemOwner","Security","SoD") or not can_approve():
        return Response("Forbidden",403)
    decision = request.form.get("decision")
    if decision not in ("Approved","Rejected"):
        return Response("Bad decision",400)
    comment = request.form.get("comment","")[:500]
    execute("UPDATE approvals SET decision=?,actor=?,comment=?,decided_utc=? WHERE ticket_id=? AND gate=? AND decision='Pending'",
            (decision,actor(),comment,now_utc(),ticket_id,gate))
    status = recalc_request_status(ticket_id)
    log_event(ticket_id,"ApprovalDecision",f"{gate}={decision}; status={status}; comment={comment}")
    flash(f"{gate}: {decision}")
    return redirect(url_for("request_detail",ticket_id=ticket_id))


@app.get("/approvals")
def approvals():
    rows = q('''SELECT a.*,r.requested_for_upn,r.role_name,r.business_justification FROM approvals a
                JOIN requests r ON r.ticket_id=a.ticket_id WHERE a.decision='Pending' ORDER BY r.created_utc''')
    return render_page("Approvals", r'''
    <div class="title-row"><div><h1>승인함</h1><div class="hint">System owner · Security · Segregation of Duties</div></div>{% if not can_approve %}<span class="badge b-bad">Not an approver</span>{% endif %}</div>
    <table><tr><th>Gate</th><th>Ticket / Target</th><th>Role</th><th>Justification</th><th>Action</th></tr>{% for x in rows %}<tr><td><b>{{ x['gate'] }}</b></td><td><a href="{{ url_for('request_detail',ticket_id=x['ticket_id']) }}">{{ x['ticket_id'] }}</a><br>{{ x['requested_for_upn'] }}</td><td>{{ x['role_name'] }}</td><td>{{ x['business_justification'] }}</td><td>{% if can_approve %}<form method="post" action="{{ url_for('decide_gate',ticket_id=x['ticket_id'],gate=x['gate']) }}"><input type="hidden" name="_csrf" value="{{ csrf_token() }}"><div class="actions"><button class="btn good sm" name="decision" value="Approved">Approve</button><button class="btn danger sm" name="decision" value="Rejected">Reject</button></div></form>{% endif %}</td></tr>{% else %}<tr><td colspan="5">승인 대기 항목이 없습니다.</td></tr>{% endfor %}</table>
    ''', rows=rows, can_approve=can_approve())


@app.post("/requests/<ticket_id>/execute")
def execute_pim(ticket_id):
    if not can_approve():
        return Response("Forbidden",403)
    row = q("SELECT * FROM requests WHERE ticket_id=?",(ticket_id,),one=True)
    if not row or row["status"] != "ApprovedReady":
        return Response("Request is not approved/ready",409)
    if row["role_name"] not in ROLE_ALLOWLIST:
        return Response("Role is outside allowlist",403)
    try:
        start = now_utc()
        end = (datetime.now(timezone.utc)+timedelta(days=row["eligibility_days"])).replace(microsecond=0).isoformat().replace("+00:00","Z")
        if MODE == "Simulation":
            graph_id = "SIM-REQ-" + uuid.uuid4().hex
            schedule_id = "SIM-SCHEDULE-" + uuid.uuid4().hex
            execute('''UPDATE requests SET status='SimulatedEligible',executed_by=?,executed_utc=?,graph_request_id=?,
                       target_schedule_id=?,graph_status='Provisioned',start_utc=?,end_utc=?,portal_owned=1,last_error=NULL,updated_utc=? WHERE ticket_id=?''',
                    (actor(),start,graph_id,schedule_id,start,end,now_utc(),ticket_id))
            log_event(ticket_id,"EligibilitySimulated",f"request={graph_id}; schedule={schedule_id}; end={end}")
            flash("Simulation eligible assignment created. No Microsoft Graph change was made.")
        else:
            user, role = resolve_user_and_role(row)
            active, eligible, pending = find_duplicate_state(user["id"],role["id"])
            if active:
                execute("UPDATE requests SET status='BlockedActiveAssignment',principal_id=?,role_definition_id=?,last_error=?,updated_utc=? WHERE ticket_id=?",
                        (user["id"],role["id"],"Existing active assignment detected",now_utc(),ticket_id))
                log_event(ticket_id,"ExecutionBlocked","Existing active assignment detected")
                flash("Existing ACTIVE assignment detected. New eligible request was blocked.")
                return redirect(url_for("request_detail",ticket_id=ticket_id))
            if eligible:
                existing = eligible[0]
                execute("UPDATE requests SET status='EligibleGranted',principal_id=?,role_definition_id=?,target_schedule_id=?,graph_status='ExistingEligible',portal_owned=0,last_error=NULL,updated_utc=? WHERE ticket_id=?",
                        (user["id"],role["id"],existing.get("roleEligibilityScheduleId") or existing.get("id"),now_utc(),ticket_id))
                log_event(ticket_id,"ExistingEligibilityReused","Portal did not create or own this eligibility")
                flash("Existing eligible assignment found and reused. It is excluded from portal cleanup.")
                return redirect(url_for("request_detail",ticket_id=ticket_id))
            if pending:
                p = pending[0]
                execute("UPDATE requests SET status='Provisioning',principal_id=?,role_definition_id=?,graph_request_id=?,target_schedule_id=?,graph_status=?,portal_owned=0,last_error=NULL,updated_utc=? WHERE ticket_id=?",
                        (user["id"],role["id"],p.get("id"),p.get("targetScheduleId"),p.get("status"),now_utc(),ticket_id))
                log_event(ticket_id,"PendingRequestReused","Portal did not create or own this request")
                flash("Existing pending/provisioned request found and reused. It is excluded from portal cleanup.")
                return redirect(url_for("request_detail",ticket_id=ticket_id))
            body = {
                "action":"adminAssign","principalId":user["id"],"roleDefinitionId":role["id"],"directoryScopeId":"/",
                "justification":f"ITSM {ticket_id}: {row['business_justification']}",
                "ticketInfo":{"ticketNumber":ticket_id,"ticketSystem":"Internal Cloud Operations Portal Demo"},
                "scheduleInfo":{"startDateTime":start,"expiration":{"type":"afterDuration","duration":f"P{row['eligibility_days']}D"}}
            }
            validation_body = json.loads(json.dumps(body))
            validation_body["isValidationOnly"] = True
            validation = graph("POST","/roleManagement/directory/roleEligibilityScheduleRequests",body=validation_body)
            log_event(ticket_id,"GraphValidationOnlyPassed",json.dumps({"status":validation.get("status"),"id":validation.get("id")}))
            result = graph("POST","/roleManagement/directory/roleEligibilityScheduleRequests",body=body)
            target = result.get("targetScheduleId")
            status = "EligibleGranted" if target else "Provisioning"
            execute('''UPDATE requests SET status=?,executed_by=?,executed_utc=?,principal_id=?,role_definition_id=?,
                       graph_request_id=?,target_schedule_id=?,graph_status=?,start_utc=?,end_utc=?,portal_owned=1,last_error=NULL,updated_utc=? WHERE ticket_id=?''',
                    (status,actor(),start,user["id"],role["id"],result.get("id"),target,result.get("status"),start,end,now_utc(),ticket_id))
            log_event(ticket_id,"EligibilitySubmitted",json.dumps({"requestId":result.get("id"),"targetScheduleId":target,"status":result.get("status")},ensure_ascii=False))
            flash("Live PIM eligible request submitted. Run Graph state Sync if provisioning is asynchronous.")
    except Exception as ex:
        execute("UPDATE requests SET status='Failed',last_error=?,updated_utc=? WHERE ticket_id=?",(str(ex)[:2000],now_utc(),ticket_id))
        log_event(ticket_id,"ExecutionFailed",str(ex)[:1500])
        flash("Execution failed. Review Last error and managed-identity permissions.")
    return redirect(url_for("request_detail",ticket_id=ticket_id))


@app.post("/requests/<ticket_id>/sync")
def sync_request(ticket_id):
    if not can_approve():
        return Response("Forbidden",403)
    row = q("SELECT * FROM requests WHERE ticket_id=?",(ticket_id,),one=True)
    if not row or not row["graph_request_id"]:
        return Response("No tracked Graph request",409)
    if MODE == "Simulation":
        flash("Simulation record is already synchronized.")
        return redirect(url_for("request_detail",ticket_id=ticket_id))
    try:
        result = graph("GET",f"/roleManagement/directory/roleEligibilityScheduleRequests/{quote(row['graph_request_id'],safe='')}")
        target = result.get("targetScheduleId") or row["target_schedule_id"]
        status = "EligibleGranted" if target and result.get("status") in ("Provisioned","Granted","ScheduleCreated") else "Provisioning"
        if result.get("status") in ("Denied","Canceled","Failed","Revoked"):
            status = result.get("status")
        execute("UPDATE requests SET status=?,target_schedule_id=?,graph_status=?,last_error=NULL,updated_utc=? WHERE ticket_id=?",
                (status,target,result.get("status"),now_utc(),ticket_id))
        log_event(ticket_id,"GraphStateSynchronized",json.dumps({"status":result.get("status"),"targetScheduleId":target}))
        flash(f"Graph status synchronized: {result.get('status')}")
    except Exception as ex:
        execute("UPDATE requests SET last_error=?,updated_utc=? WHERE ticket_id=?",(str(ex)[:2000],now_utc(),ticket_id))
        log_event(ticket_id,"SyncFailed",str(ex)[:1500])
        flash("Sync failed.")
    return redirect(url_for("request_detail",ticket_id=ticket_id))


@app.post("/requests/<ticket_id>/revoke")
def revoke(ticket_id):
    if not can_approve():
        return Response("Forbidden",403)
    row = q("SELECT * FROM requests WHERE ticket_id=?",(ticket_id,),one=True)
    if not row or request.form.get("confirm") != ticket_id or not row["portal_owned"] or not row["target_schedule_id"]:
        return Response("Tracked schedule and exact confirmation are required",409)
    try:
        if MODE != "Simulation":
            body = {"action":"adminRemove","principalId":row["principal_id"],"roleDefinitionId":row["role_definition_id"],
                    "directoryScopeId":"/","targetScheduleId":row["target_schedule_id"],
                    "justification":f"Portal tracked cleanup for ITSM {ticket_id}"}
            result = graph("POST","/roleManagement/directory/roleEligibilityScheduleRequests",body=body)
            details = json.dumps({"removalRequestId":result.get("id"),"targetScheduleId":row["target_schedule_id"]})
        else:
            details = "Simulation revoke"
        execute("UPDATE requests SET status='Revoked',graph_status='RemovalSubmitted',updated_utc=? WHERE ticket_id=?",(now_utc(),ticket_id))
        log_event(ticket_id,"EligibilityRevoked",details)
        flash("Tracked eligibility removal submitted. Existing/non-owned PIM objects were not touched.")
    except Exception as ex:
        execute("UPDATE requests SET last_error=?,updated_utc=? WHERE ticket_id=?",(str(ex)[:2000],now_utc(),ticket_id))
        log_event(ticket_id,"RevokeFailed",str(ex)[:1500])
        flash("Revoke failed.")
    return redirect(url_for("request_detail",ticket_id=ticket_id))


@app.get("/pim")
def pim_assignments():
    rows = q("SELECT * FROM requests WHERE graph_request_id IS NOT NULL ORDER BY created_utc DESC")
    return render_page("PIM assignments", r'''
    <div class="title-row"><div><h1>Entra PIM 역할 할당</h1><div class="hint">Active → Eligible → Pending 순서의 중복 방어 후 adminAssign을 수행합니다.</div></div></div>
    <div class="okbox"><b>Allowlist</b>: {{ roles|join(', ') }}</div>
    <table style="margin-top:16px"><tr><th>Ticket</th><th>Principal / Role</th><th>Graph status</th><th>Eligible window</th><th>Ownership / Policy</th></tr>{% for x in rows %}<tr><td><a href="{{ url_for('request_detail',ticket_id=x['ticket_id']) }}">{{ x['ticket_id'] }}</a></td><td>{{ x['requested_for_upn'] }}<br>{{ x['role_name'] }}</td><td>{{ status_badge(x['graph_status'] or x['status']) }}<div class="mono">{{ x['graph_request_id'] }}</div></td><td>{{ x['start_utc'] or '-' }}<br>{{ x['end_utc'] or '-' }}</td><td>{{ 'Portal tracked' if x['portal_owned'] else 'Existing / not owned' }}<br><a class="btn alt sm" href="{{ url_for('policy_snapshot',ticket_id=x['ticket_id']) }}">PIM policy rules</a></td></tr>{% else %}<tr><td colspan="5">Executed assignments are not available.</td></tr>{% endfor %}</table>
    ''', rows=rows, roles=ROLE_ALLOWLIST)


@app.get("/requests/<ticket_id>/policy")
def policy_snapshot(ticket_id):
    row = q("SELECT * FROM requests WHERE ticket_id=?",(ticket_id,),one=True)
    if not row:
        return Response("Not found",404)
    try:
        if MODE == "Simulation":
            payload = {
                "mode":"Simulation","roleName":row["role_name"],
                "explanation":"Live mode reads the roleManagementPolicyAssignment and its rules from Microsoft Graph.",
                "requestedActivationHours":row["activation_hours"],
                "controlsToDemonstrate":["MFA on activation","Justification","Approval when configured","Maximum activation duration","Notification"]
            }
        else:
            role_id = row["role_definition_id"]
            if not role_id:
                _, role = resolve_user_and_role(row)
                role_id = role["id"]
            filter_text = f"scopeId eq '/' and scopeType eq 'DirectoryRole' and roleDefinitionId eq '{role_id}'"
            assignments = graph_values("/policies/roleManagementPolicyAssignments",params={"$filter":filter_text})
            policies = []
            for assignment in assignments:
                policy_id = assignment.get("policyId")
                rules = graph_values(f"/policies/roleManagementPolicies/{policy_id}/rules") if policy_id else []
                policies.append({"assignment":assignment,"rules":rules})
            payload = {"roleName":row["role_name"],"roleDefinitionId":role_id,"policies":policies}
        text = json.dumps(payload,indent=2,ensure_ascii=False)
        log_event(ticket_id,"PimPolicySnapshotViewed",f"Mode={MODE}")
        return render_page("PIM policy snapshot",r'''<div class="title-row"><div><h1>PIM Policy Snapshot</h1><div class="hint">{{ ticket }} · 요청값과 실제 PIM 집행 정책의 경계를 확인합니다.</div></div><a class="btn alt" href="{{ url_for('pim_assignments') }}">Back</a></div><pre>{{ text }}</pre>''',ticket=ticket_id,text=text)
    except Exception as ex:
        log_event(ticket_id,"PimPolicySnapshotFailed",str(ex)[:1500])
        return render_page("PIM policy error",r'''<h1>PIM Policy Snapshot</h1><div class="dangerbox">{{ message }}</div>''',message=str(ex)),500


@app.get("/activation")
def activation():
    return render_page("PIM activation", r'''
    <div class="title-row"><div><h1>PIM 활성화 Handoff</h1><div class="hint">Internal ITSM 승인은 Active 권한을 직접 부여하지 않습니다.</div></div><a class="btn" target="_blank" href="{{ pim_url }}">Open My roles</a></div>
    <div class="flow"><div class="step"><strong>Eligible 확인</strong>My roles에서 Role 선택</div><div class="step"><strong>Activate</strong>요청 시간·사유 입력</div><div class="step"><strong>MFA</strong>PIM 정책 조건 충족</div><div class="step"><strong>Approval</strong>정책상 필요한 경우</div><div class="step"><strong>Auto expiry</strong>활성화 시간 종료</div></div>
    <div class="warning"><b>중요:</b> 포털의 activationHours는 ITSM 요청값입니다. 실제 MFA, 승인자, Ticket 요구, 최대 활성화 시간은 Entra PIM Role management policy를 구성하여 집행해야 합니다.</div>
    ''', pim_url=PIM_ACTIVATION_URL)


@app.get("/expiry")
def expiry():
    rows = q("SELECT * FROM requests WHERE graph_request_id IS NOT NULL ORDER BY end_utc")
    return render_page("Expiry and revoke", r'''
    <div class="title-row"><div><h1>만료 시점 및 긴급 회수</h1><div class="hint">기간 종료를 기본으로 하고, 긴급 상황에서 Portal-owned schedule만 회수합니다.</div></div></div>
    <table><tr><th>Ticket</th><th>Role</th><th>End UTC</th><th>Status</th><th>Scoped action</th></tr>{% for x in rows %}<tr><td><a href="{{ url_for('request_detail',ticket_id=x['ticket_id']) }}">{{ x['ticket_id'] }}</a></td><td>{{ x['requested_for_upn'] }}<br>{{ x['role_name'] }}</td><td>{{ x['end_utc'] or 'Pending sync' }}</td><td>{{ status_badge(x['status']) }}</td><td>{% if x['portal_owned'] and x['target_schedule_id'] and x['status']!='Revoked' and can_approve %}<form method="post" action="{{ url_for('revoke',ticket_id=x['ticket_id']) }}"><input type="hidden" name="_csrf" value="{{ csrf_token() }}"><input type="hidden" name="confirm" value="{{ x['ticket_id'] }}"><button class="btn danger sm">Revoke tracked</button></form>{% else %}<span class="hint">Not owned / no operator access</span>{% endif %}</td></tr>{% else %}<tr><td colspan="5">No tracked schedules</td></tr>{% endfor %}</table>
    {% if can_approve %}<div class="dangerbox" style="margin-top:20px"><b>Scoped bulk cleanup</b><br>기존 고객 PIM 객체는 제외하고 Portal DB에서 portal_owned=1로 추적된 Schedule만 회수합니다.<form method="post" action="{{ url_for('cleanup_tracked_eligibilities') }}" style="margin-top:10px"><input type="hidden" name="_csrf" value="{{ csrf_token() }}"><label>강한 확인</label><input name="confirm" placeholder="REMOVE-PORTAL-TRACKED"><button class="btn danger" style="margin-top:8px">모든 Portal-tracked eligibility 회수</button></form></div>{% endif %}
    ''', rows=rows, can_approve=can_approve())


@app.post("/cleanup/tracked-eligibilities")
def cleanup_tracked_eligibilities():
    if not can_approve():
        return Response("Forbidden",403)
    if request.form.get("confirm") != "REMOVE-PORTAL-TRACKED":
        flash("Strong confirmation mismatch. Cleanup cancelled.")
        return redirect(url_for("expiry"))
    rows = q("SELECT * FROM requests WHERE portal_owned=1 AND target_schedule_id IS NOT NULL AND status!='Revoked'")
    succeeded = 0
    failed = 0
    for row in rows:
        try:
            if MODE != "Simulation":
                body = {"action":"adminRemove","principalId":row["principal_id"],"roleDefinitionId":row["role_definition_id"],
                        "directoryScopeId":"/","targetScheduleId":row["target_schedule_id"],
                        "justification":f"Scoped portal cleanup for ITSM {row['ticket_id']}"}
                result = graph("POST","/roleManagement/directory/roleEligibilityScheduleRequests",body=body)
                details = json.dumps({"removalRequestId":result.get("id"),"targetScheduleId":row["target_schedule_id"]})
            else:
                details = "Simulation scoped bulk revoke"
            execute("UPDATE requests SET status='Revoked',graph_status='RemovalSubmitted',updated_utc=? WHERE ticket_id=?",
                    (now_utc(),row["ticket_id"]))
            log_event(row["ticket_id"],"BulkEligibilityRevoked",details)
            succeeded += 1
        except Exception as ex:
            execute("UPDATE requests SET last_error=?,updated_utc=? WHERE ticket_id=?",(str(ex)[:2000],now_utc(),row["ticket_id"]))
            log_event(row["ticket_id"],"BulkRevokeFailed",str(ex)[:1500])
            failed += 1
    flash(f"Scoped cleanup completed. succeeded={succeeded}; failed={failed}; non-owned objects were excluded.")
    return redirect(url_for("expiry"))


def rows_to_csv(rows):
    buf = io.StringIO()
    if rows:
        writer = csv.DictWriter(buf,fieldnames=rows[0].keys())
        writer.writeheader()
        for row in rows: writer.writerow(dict(row))
    return buf.getvalue().encode("utf-8-sig")


@app.get("/evidence.zip")
def evidence_zip():
    request_rows = q("SELECT * FROM requests ORDER BY created_utc")
    approval_rows = q("SELECT * FROM approvals ORDER BY ticket_id,gate")
    event_rows = q("SELECT * FROM events ORDER BY id")
    files = {
        "requests.csv": rows_to_csv(request_rows),
        "approvals.csv": rows_to_csv(approval_rows),
        "events.csv": rows_to_csv(event_rows),
        "portal-config.json": json.dumps({"version":APP_VERSION,"mode":MODE,"roleAllowlist":ROLE_ALLOWLIST,
                                          "generatedUtc":now_utc()},indent=2,ensure_ascii=False).encode("utf-8")
    }
    manifest = io.StringIO()
    w = csv.writer(manifest); w.writerow(["File","SHA256","Length"])
    for name,data in files.items(): w.writerow([name,hashlib.sha256(data).hexdigest().upper(),len(data)])
    files["SHA256-MANIFEST.csv"] = manifest.getvalue().encode("utf-8-sig")
    payload = io.BytesIO()
    with zipfile.ZipFile(payload,"w",zipfile.ZIP_DEFLATED) as z:
        for name,data in files.items(): z.writestr(name,data)
    payload.seek(0)
    log_event(None,"EvidenceExported",f"Files={len(files)}")
    return send_file(payload,mimetype="application/zip",as_attachment=True,
                     download_name="FIN-PIM-ITSM-Evidence-"+datetime.now().strftime("%Y%m%d-%H%M%S")+".zip")


@app.get("/audit")
def audit():
    events = q("SELECT * FROM events ORDER BY id DESC LIMIT 100")
    return render_page("Audit and evidence", r'''
    <div class="title-row"><div><h1>감사·증적</h1><div class="hint">Ticket, approval, Graph correlation, 만료/회수와 파일 무결성을 연결합니다.</div></div><a class="btn" href="{{ url_for('evidence_zip') }}">Evidence ZIP 다운로드</a></div>
    <div class="grid"><div class="card"><h3>requests.csv</h3><div class="hint">요청·역할·기간·Graph ID</div></div><div class="card"><h3>approvals.csv</h3><div class="hint">Owner·Security·SoD 결정</div></div><div class="card"><h3>events.csv</h3><div class="hint">시간순 실행·오류·회수</div></div><div class="card"><h3>SHA256-MANIFEST.csv</h3><div class="hint">증적 파일 무결성</div></div></div>
    <h2 style="margin-top:24px">Latest events</h2><table><tr><th>UTC</th><th>Ticket</th><th>Actor</th><th>Event</th><th>Details</th></tr>{% for e in events %}<tr><td>{{ e['created_utc'] }}</td><td>{{ e['ticket_id'] or '-' }}</td><td>{{ e['actor'] }}</td><td>{{ e['event_type'] }}</td><td>{{ e['details'] }}</td></tr>{% endfor %}</table>
    ''', events=events)


@app.get("/settings")
def settings():
    token_state = "Not tested"
    if MODE == "Live":
        try:
            managed_identity_token(); token_state="Managed identity token OK"
        except Exception as ex:
            token_state="Token error: "+str(ex)
    return render_page("Settings", r'''
    <div class="title-row"><div><h1>Demo 설정 및 Health</h1><div class="hint">비밀 값은 표시하지 않습니다.</div></div></div>
    <div class="grid"><div class="card"><h3>Portal mode</h3><div class="metric">{{ mode }}</div></div><div class="card"><h3>Easy Auth identity</h3><b>{{ actor_name }}</b></div><div class="card"><h3>Managed Identity</h3><div class="hint">{{ token_state }}</div></div><div class="card"><h3>Database</h3><div class="mono">{{ db_path }}</div></div></div>
    <h2 style="margin-top:24px">Role allowlist</h2><pre>{{ roles|join('\n') }}</pre>
    <div class="warning">Production 권고: APIM/mTLS/JWT schema validation, Service Bus queue/retry/replay protection, Key Vault secret or identity-based auth, private networking, centralized Log Analytics/Sentinel, immutable evidence store를 추가하십시오.</div>
    ''', mode=MODE, actor_name=actor(), token_state=token_state, db_path=DB_PATH, roles=ROLE_ALLOWLIST)


@app.errorhandler(Exception)
def handle_error(ex):
    if isinstance(ex, HTTPException):
        return ex
    app.logger.exception("Unhandled portal error")
    return render_page("Error",r'''<h1>Portal error</h1><div class="dangerbox"><b>{{ message }}</b></div><p><a class="btn alt" href="{{ url_for('dashboard') }}">Dashboard</a></p>''',message=str(ex)),500


if __name__ == "__main__":
    app.run(host="0.0.0.0",port=int(os.getenv("PORT","8000")),debug=False)
'@

    $requirements = @'
Flask==3.1.0
gunicorn==23.0.0
requests==2.32.3
'@
    $readme = @'
# Entra PIM + Internal ITSM Sample Portal

Generated by Entra-PIM-ITSM-Financial-Portal-Launcher-v2.0.5.1.ps1.

## Runtime
- Azure App Service Linux / Python 3.11
- Flask + Gunicorn
- SQLite under `/home/data` (single-instance demo only)
- App Service Authentication with Microsoft Entra ID
- System-assigned managed identity for optional Microsoft Graph access

## Safe default
`PIM_PORTAL_MODE=Simulation` implements the complete portal workflow but does not write to Microsoft Graph.
Live mode requires the launcher's explicit managed-identity app-role grant and an approved test tenant.

## Production boundary
This sample is not a production ITSM product. Replace SQLite with a managed data store, implement enterprise authorization and workflow integration, use private networking and centralized monitoring, and place external integration behind APIM and a queue.
'@
    Write-Utf8NoBom -Path (Join-Path $source 'app.py') -Content $appPy
    Write-Utf8NoBom -Path (Join-Path $source 'requirements.txt') -Content $requirements
    Write-Utf8NoBom -Path (Join-Path $source 'README.md') -Content $readme

    $requiredRouteMarkers=@('@app.get("/health")','@app.get("/route-manifest")','@app.get("/")','@app.route("/requests/new"','@app.get("/requests")','@app.get("/approvals")','@app.get("/pim")','@app.get("/activation")','@app.get("/expiry")','@app.get("/audit")','@app.get("/settings")')
    $generatedApp=Get-Content -LiteralPath (Join-Path $source 'app.py') -Raw
    $missingRouteMarkers=@($requiredRouteMarkers | Where-Object {$generatedApp.IndexOf($_,[System.StringComparison]::Ordinal) -lt 0})
    if($missingRouteMarkers.Count -gt 0){throw ("Generated app.py is missing route marker(s): {0}" -f ($missingRouteMarkers -join ', '))}
    if($generatedApp -notmatch 'APP_VERSION = "2\.0\.5\.1"'){throw 'Generated app.py version marker is invalid.'}

    $package = Get-PortalPackagePath
    if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Force }
    Compress-Archive -Path (Join-Path $source '*') -DestinationPath $package -CompressionLevel Optimal -Force
    $script:State.LocalSourcePath = $source
    $script:State.LocalPackagePath = $package
    Save-State
    Write-Log "Portal source generated: $source" 'OK'
    Write-Log "Deployment ZIP generated: $package" 'OK'
}

function Get-WebAppSettingsHashtable {
    param([string]$ResourceGroup,[string]$Name)
    $hash = @{}
    $app = Get-AzWebApp -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop
    foreach ($item in @($app.SiteConfig.AppSettings)) {
        if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.Name)) { $hash[[string]$item.Name] = [string]$item.Value }
    }
    return $hash
}

function Set-WebAppSettingsMerged {
    param([hashtable]$Values)
    Assert-AzConnected; Assert-Configuration
    $settings = Get-WebAppSettingsHashtable -ResourceGroup $script:State.ResourceGroupName -Name $script:State.WebAppName
    foreach ($key in $Values.Keys) { $settings[$key] = [string]$Values[$key] }
    Set-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName -AppSettings $settings | Out-Null
}

function New-WhatIfDeploymentPlan {
    Assert-AzConnected; Assert-GraphConnected; Assert-Configuration
    Write-Log 'Collecting read-only Azure and Entra state...' 'STEP'
    $rg = Get-AzResourceGroup -Name $script:State.ResourceGroupName -ErrorAction SilentlyContinue
    $plan = $null
    $web = $null
    if ($rg) {
        $plan = Get-AzAppServicePlan -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.AppServicePlanName -ErrorAction SilentlyContinue
        $web = Get-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName -ErrorAction SilentlyContinue
    }
    $authAppExists = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$script:State.AuthApplicationObjectId)) {
        try { [void](Invoke-Graph GET ("/applications/{0}?`$select=id,appId,displayName" -f $script:State.AuthApplicationObjectId)); $authAppExists=$true } catch { $authAppExists=$false }
    }
    $actions = @()
    $actions += if($rg){'Reuse resource group'}else{'Create resource group'}
    $actions += if($plan){'Reuse App Service plan'}else{'Create Linux Basic App Service plan'}
    $actions += if($web){'Reuse Web App'}else{'Create Python 3.11 Web App with system-assigned managed identity'}
    $actions += if($authAppExists){'Reuse tracked Entra authentication application'}else{'Create single-tenant Entra authentication application and short-lived secret'}
    $actions += 'Configure App Service Authentication; require same-tenant sign-in'
    $actions += 'Deploy generated Flask/SQLite demo portal package'
    if ($script:State.PortalMode -eq 'Live') {
        $actions += 'OPTIONAL CHANGE: grant five Microsoft Graph application roles to Web App managed identity'
        $actions += 'OPTIONAL CHANGE: enable live roleEligibilityScheduleRequests adminAssign/adminRemove'
    } else {
        $actions += 'Keep portal in Simulation mode; no Microsoft Graph PIM write'
    }
    $whatIf = [pscustomobject]@{
        GeneratedUtc=Get-UtcNowText; Execution='No change - preview only'
        TenantId=$script:State.TenantId; SubscriptionId=$script:State.SubscriptionId; Location=$script:State.Location
        ResourceGroup=$script:State.ResourceGroupName; WebApp=$script:State.WebAppName; PortalMode=$script:State.PortalMode
        Existing=[pscustomobject]@{ ResourceGroup=[bool]$rg; AppServicePlan=[bool]$plan; WebApp=[bool]$web; AuthApplication=$authAppExists }
        Actions=$actions
        GraphRolesForLive=$script:PortalGraphAppRoles
        CleanupBoundary='Only launcher-state-tracked Azure objects, authentication app and newly-created app-role assignments'
    }
    Ensure-Directory
    $path = Join-Path $OutputRoot ('WhatIf-DeploymentPlan-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $whatIf | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8
    $script:State.WhatIfPlanPath = $path
    Save-State
    $whatIf | ConvertTo-Json -Depth 20 | Write-Host
    Write-Log "WhatIf plan exported: $path" 'OK'
}

function Deploy-AzureInfrastructure {
    Assert-AzConnected; Assert-Configuration
    Write-Host ''
    Write-Host 'Menu 6 - Deploy Azure App Service infrastructure' -ForegroundColor White
    if (-not (Confirm-ExactText -Prompt 'This creates or updates Azure resources. The Web App starts in the configured portal mode.' -Expected ("DEPLOY-{0}" -f $script:State.WebAppName))) {
        Write-Log 'Deployment cancelled.' 'WARN'; return
    }

    $rg = Get-AzResourceGroup -Name $script:State.ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        Write-Log ("Creating resource group {0}" -f $script:State.ResourceGroupName) 'STEP'
        $rg = New-AzResourceGroup -Name $script:State.ResourceGroupName -Location $script:State.Location
        $script:State.ResourceGroupCreatedByLauncher = $true
        Add-CreatedResource -Type 'Microsoft.Resources/resourceGroups' -Name $rg.ResourceGroupName -Id $rg.ResourceId
    } else { Write-Log 'Reusing existing resource group; full cleanup will not delete the group.' 'WARN' }

    $plan = Get-AzAppServicePlan -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.AppServicePlanName -ErrorAction SilentlyContinue
    if (-not $plan) {
        Write-Log 'Creating Linux Basic App Service plan (single worker).' 'STEP'
        $plan = New-AzAppServicePlan -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.AppServicePlanName -Location $script:State.Location -Tier Basic -WorkerSize Small -NumberofWorkers 1 -Linux
        Add-CreatedResource -Type 'Microsoft.Web/serverfarms' -Name $script:State.AppServicePlanName -Id $plan.Id
    } else { Write-Log 'Reusing existing App Service plan.' 'OK' }

    $web = Get-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName -ErrorAction SilentlyContinue
    if (-not $web) {
        Write-Log 'Creating Azure Web App.' 'STEP'
        $web = New-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName -Location $script:State.Location -AppServicePlan $script:State.AppServicePlanName
        Add-CreatedResource -Type 'Microsoft.Web/sites' -Name $script:State.WebAppName -Id $web.Id
    } else { Write-Log 'Reusing existing Web App.' 'OK' }

    $siteId = [string]$web.Id
    $sitePatch = @{
        identity=@{type='SystemAssigned'}
        properties=@{
            httpsOnly=$true; clientAffinityEnabled=$false
            siteConfig=@{
                linuxFxVersion='PYTHON|3.11'; alwaysOn=$true; ftpsState='Disabled'; minTlsVersion='1.2'; http20Enabled=$true
                appCommandLine='gunicorn --bind=0.0.0.0:8000 --workers=2 --threads=4 --timeout=180 app:app'
            }
        }
    }
    [void](Invoke-Arm -Method PATCH -Path ("{0}?api-version=2023-12-01" -f $siteId) -Body $sitePatch)

    $principalId = $null
    for ($i=0; $i -lt 12 -and [string]::IsNullOrWhiteSpace([string]$principalId); $i++) {
        Start-Sleep -Seconds 5
        $web = Get-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName
        $principalId = Get-PropertyValue (Get-PropertyValue $web 'Identity' $null) 'PrincipalId' $null
    }
    if ([string]::IsNullOrWhiteSpace([string]$principalId)) { throw 'System-assigned managed identity principalId was not provisioned.' }

    $appSettings = @{
        'SCM_DO_BUILD_DURING_DEPLOYMENT'='true'
        'WEBSITES_ENABLE_APP_SERVICE_STORAGE'='true'
        'PYTHONUNBUFFERED'='1'
        'PIM_PORTAL_NAME'='Customer Cloud Operations Portal'
        'PIM_PORTAL_MODE'=[string]$script:State.PortalMode
        'PIM_DB_PATH'='/home/data/pim-demo.db'
        'PIM_ROLE_ALLOWLIST'='User Administrator,Groups Administrator,Authentication Administrator,Helpdesk Administrator'
        'PIM_SAMPLE_USER_UPN'=$SampleUserUpn
        'PIM_APPROVER_ALLOWLIST'=$ApproverAllowList
        'FLASK_SECRET_KEY'=(New-RandomText -Bytes 48)
    }
    Set-WebAppSettingsMerged -Values $appSettings

    $script:State.WebAppResourceId=$siteId
    $script:State.WebAppHostName=("{0}.azurewebsites.net" -f $script:State.WebAppName)
    $script:State.WebAppManagedIdentityObjectId=[string]$principalId
    Save-State
    Write-Log ("Infrastructure ready. WebApp={0}; MI={1}" -f $script:State.WebAppName,$principalId) 'OK'
}

function Get-OrCreate-AuthApplication {
    Assert-GraphConnected; Assert-Configuration
    $appObject = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$script:State.AuthApplicationObjectId)) {
        try { $appObject = Invoke-Graph GET ("/applications/{0}?`$select=id,appId,displayName,web" -f $script:State.AuthApplicationObjectId) }
        catch { Write-Log 'Tracked authentication application was not found; a new one will be created.' 'WARN' }
    }
    if ($null -eq $appObject) {
        # Do not use $home: PowerShell variable names are case-insensitive and $HOME is read-only.
        $portalBaseUrl = "https://$($script:State.WebAppName).azurewebsites.net"
        $body = @{
            displayName=("{0} Portal Auth - {1}" -f $AssetPrefix,$script:State.WebAppName)
            signInAudience='AzureADMyOrg'
            web=@{
                homePageUrl=$portalBaseUrl
                logoutUrl=("{0}/.auth/logout" -f $portalBaseUrl)
                redirectUris=@(("{0}/.auth/login/aad/callback" -f $portalBaseUrl))
                implicitGrantSettings=@{enableIdTokenIssuance=$true;enableAccessTokenIssuance=$false}
            }
        }
        $appObject = Invoke-Graph POST '/applications' $body
        $sp = Invoke-Graph POST '/servicePrincipals' @{appId=[string]$appObject.appId;accountEnabled=$true}
        $script:State.AuthApplicationObjectId=[string]$appObject.id
        $script:State.AuthApplicationClientId=[string]$appObject.appId
        $script:State.AuthServicePrincipalObjectId=[string]$sp.id
        Save-State
        Write-Log ("Authentication application created: {0}" -f $appObject.appId) 'OK'
    }
    return $appObject
}

function Configure-AppServiceAuthentication {
    Assert-AzConnected; Assert-GraphConnected; Assert-Configuration
    if([string]::IsNullOrWhiteSpace([string]$script:State.WebAppResourceId)){throw 'Run menu 6 first.'}
    if(-not(Confirm-ExactText -Prompt 'This rotates the Easy Auth secret, repairs the app registration and enables mandatory same-tenant sign-in.' -Expected ("AUTH-{0}" -f $script:State.WebAppName))){Write-Log 'Authentication configuration cancelled.' 'WARN';return}

    $appObject=Get-OrCreate-AuthApplication
    $portalBaseUrl="https://$($script:State.WebAppName).azurewebsites.net"
    $redirectUri=("{0}/.auth/login/aad/callback" -f $portalBaseUrl)
    $tenantId=[string]$script:State.TenantId
    $clientId=[string]$appObject.appId
    if([string]::IsNullOrWhiteSpace($clientId)){throw 'Authentication application client ID is empty.'}
    $script:State.AuthApplicationObjectId=[string]$appObject.id
    $script:State.AuthApplicationClientId=$clientId

    # Repair the Web platform on every run so redirect URI drift cannot survive.
    [void](Invoke-Graph PATCH ("/applications/{0}" -f $script:State.AuthApplicationObjectId) @{
        signInAudience='AzureADMyOrg'
        web=@{homePageUrl=$portalBaseUrl;logoutUrl=("{0}/.auth/logout" -f $portalBaseUrl);redirectUris=@($redirectUri);implicitGrantSettings=@{enableIdTokenIssuance=$true;enableAccessTokenIssuance=$false}}
    })

    # Always rotate the secret. Never trust a pre-existing App Setting whose original value cannot be compared with Graph.
    $secretSettingName='MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
    $end=(Get-Date).ToUniversalTime().AddDays($AuthSecretLifetimeDays)
    $password=Invoke-Graph POST ("/applications/{0}/addPassword" -f $script:State.AuthApplicationObjectId) @{
        passwordCredential=@{displayName=("App Service Easy Auth v2.0.5.1 {0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'));endDateTime=$end.ToString('o')}
    }
    $secretValue=[string]$password.secretText
    if([string]::IsNullOrWhiteSpace($secretValue)){throw 'Graph did not return the new authentication secret value.'}
    Set-WebAppSettingsMerged -Values @{$secretSettingName=$secretValue}
    $settingsAfter=Get-WebAppSettingsHashtable -ResourceGroup $script:State.ResourceGroupName -Name $script:State.WebAppName
    if(-not $settingsAfter.ContainsKey($secretSettingName) -or [string]::IsNullOrWhiteSpace([string]$settingsAfter[$secretSettingName])){throw 'Easy Auth secret App Setting read-back failed.'}
    $script:TransientAuthSecret=$secretValue
    $script:State.AuthSecretExpiresUtc=$end.ToString('o')
    Save-State
    Write-Log 'A new short-lived client secret was generated and its VALUE was stored in the protected App Service setting.' 'OK'

    $issuer=("https://login.microsoftonline.com/{0}/v2.0" -f $tenantId)
    $metadataUrl=("{0}/.well-known/openid-configuration" -f $issuer)
    try {
        $metadataResponse=Invoke-WebRequest -Uri $metadataUrl -UseBasicParsing -TimeoutSec 30
        if([int]$metadataResponse.StatusCode -ne 200){throw "HTTP $($metadataResponse.StatusCode)"}
        $metadataObject=([string]$metadataResponse.Content) | ConvertFrom-Json
        if([string]::IsNullOrWhiteSpace([string]$metadataObject.authorization_endpoint) -or [string]::IsNullOrWhiteSpace([string]$metadataObject.token_endpoint)){throw 'Metadata endpoints are missing.'}
    } catch { throw ("OpenID metadata validation failed for {0}: {1}" -f $metadataUrl,$_.Exception.Message) }
    $authPayload=@{properties=@{
        platform=@{enabled=$true;runtimeVersion='~1'}
        globalValidation=@{requireAuthentication=$true;unauthenticatedClientAction='RedirectToLoginPage';redirectToProvider='azureActiveDirectory';excludedPaths=@('/health','/route-manifest')}
        identityProviders=@{azureActiveDirectory=@{enabled=$true;registration=@{openIdIssuer=$issuer;clientId=$clientId;clientSecretSettingName=$secretSettingName};validation=@{allowedAudiences=@($clientId,("api://{0}" -f $clientId))}}}
        login=@{tokenStore=@{enabled=$true};preserveUrlFragmentsForLogins=$false}
        httpSettings=@{requireHttps=$true;routes=@{apiPrefix='/.auth'};forwardProxy=@{convention='NoProxy'}}
    }}
    [void](Invoke-Arm PUT ("{0}/config/authsettingsV2?api-version=2023-12-01" -f $script:State.WebAppResourceId) $authPayload)

    # Read back every linkage before restart.
    $authRead=Invoke-Arm GET ("{0}/config/authsettingsV2?api-version=2023-12-01" -f $script:State.WebAppResourceId)
    $aad=$authRead.properties.identityProviders.azureActiveDirectory
    $registration=$aad.registration
    $problems=@()
    if(-not [bool]$authRead.properties.platform.enabled){$problems+='Auth platform disabled'}
    if([string]$registration.clientId -ne $clientId){$problems+='Client ID mismatch'}
    if([string]$registration.clientSecretSettingName -ne $secretSettingName){$problems+='Secret setting-name mismatch'}
    if(([string]$registration.openIdIssuer).TrimEnd('/') -ne $issuer.TrimEnd('/')){$problems+='Issuer mismatch'}
    $appRead=Invoke-Graph GET ("/applications/{0}?`$select=id,appId,signInAudience,web,passwordCredentials" -f $script:State.AuthApplicationObjectId)
    if([string]$appRead.appId -ne $clientId){$problems+='Graph application client ID mismatch'}
    if(@($appRead.web.redirectUris) -notcontains $redirectUri){$problems+='Redirect URI missing'}
    if(-not [bool]$appRead.web.implicitGrantSettings.enableIdTokenIssuance){$problems+='ID token issuance is disabled'}
    if([bool]$appRead.web.implicitGrantSettings.enableAccessTokenIssuance){$problems+='Access token implicit issuance should remain disabled'}
    $credentialMatch=@($appRead.passwordCredentials | Where-Object {[string]$_.keyId -eq [string]$password.keyId})
    if($credentialMatch.Count -ne 1){$problems+='New password credential not visible in Graph'}
    if($problems.Count -gt 0){throw ("Easy Auth linkage verification failed: {0}" -f ($problems -join '; '))}

    $script:State.AuthIssuer=$issuer
    $script:State.AuthMetadataUrl=$metadataUrl
    $script:State.AuthLastRepairUtc=Get-UtcNowText
    Save-State
    Write-Log 'Flushing Easy Auth runtime cache with Web App Stop/Start/Restart...' 'STEP'
    Stop-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName | Out-Null
    Start-Sleep -Seconds 8
    Start-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName | Out-Null
    Start-Sleep -Seconds 12
    Restart-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName | Out-Null
    $script:TransientAuthSecret=$null
    Write-Log ("Easy Auth repaired and verified. ClientId={0}; RedirectUri={1}; Issuer={2}" -f $clientId,$redirectUri,$issuer) 'OK'
    Write-Log 'Easy Auth cache was flushed with Stop/Start/Restart. Use a new InPrivate window after validation.' 'OK'
}

function Grant-ManagedIdentityGraphPermissions {
    Assert-GraphConnected; Assert-AzConnected; Assert-Configuration
    $mi = [string]$script:State.WebAppManagedIdentityObjectId
    if ([string]::IsNullOrWhiteSpace($mi)) { throw 'Run menu 6 first; managed identity is not tracked.' }
    Write-Host ''
    Write-Host 'WARNING: This grants Microsoft Graph APPLICATION permissions to the Web App managed identity.' -ForegroundColor Red
    $script:PortalGraphAppRoles | ForEach-Object { Write-Host (" - {0}" -f $_) -ForegroundColor Yellow }
    Write-Host 'RoleEligibilitySchedule.ReadWrite.Directory can create/remove Entra directory-role eligibility.' -ForegroundColor Red
    if (-not (Confirm-ExactText -Prompt 'Use only in an approved test tenant. This also switches the portal to Live mode.' -Expected ("GRANT-LIVE-{0}" -f $script:State.WebAppName))) {
        Write-Log 'Managed identity permission grant cancelled.' 'WARN'; return
    }

    $result = Invoke-Graph GET ("/servicePrincipals?`$filter=appId eq '{0}'&`$select=id,appId,displayName,appRoles" -f $script:GraphServicePrincipalAppId)
    $graphSp = @($result.value)[0]
    if ($null -eq $graphSp) { throw 'Microsoft Graph service principal was not found.' }
    $existing = Get-AllGraphPages ("/servicePrincipals/{0}/appRoleAssignments?`$select=id,appRoleId,resourceId,principalId" -f $mi)
    $created = @($script:State.GraphAppRoleAssignments)
    foreach ($permission in $script:PortalGraphAppRoles) {
        $role = @($graphSp.appRoles | Where-Object { $_.value -eq $permission -and $_.isEnabled -and @($_.allowedMemberTypes) -contains 'Application' })
        if ($role.Count -ne 1) { throw "Microsoft Graph application role not uniquely resolved: $permission" }
        $already = @($existing | Where-Object { [string]$_.appRoleId -eq [string]$role[0].id -and [string]$_.resourceId -eq [string]$graphSp.id })
        if ($already.Count -gt 0) {
            Write-Log "$permission already exists; it is not added to launcher-owned cleanup state." 'WARN'
            continue
        }
        $assignment = Invoke-Graph POST ("/servicePrincipals/{0}/appRoleAssignments" -f $mi) @{
            principalId=$mi;resourceId=[string]$graphSp.id;appRoleId=[string]$role[0].id
        }
        $created += [pscustomobject]@{
            AssignmentId=[string]$assignment.id; Permission=$permission; PrincipalId=$mi; ResourceId=[string]$graphSp.id
            CreatedUtc=Get-UtcNowText
        }
        Write-Log "$permission granted." 'OK'
    }
    $script:State.GraphAppRoleAssignments=@($created)
    $script:State.PortalMode='Live'
    Set-WebAppSettingsMerged -Values @{'PIM_PORTAL_MODE'='Live'}
    Save-State
    Restart-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName | Out-Null
    Write-Log 'Portal switched to Live mode. Managed identity role changes may take time because tokens are cached.' 'WARN'
}

function Deploy-PortalPackage {
    Assert-AzConnected; Assert-Configuration
    $package = [string]$script:State.LocalPackagePath
    if ([string]::IsNullOrWhiteSpace($package) -or -not (Test-Path -LiteralPath $package)) { throw 'Run menu 4 to generate the portal package first.' }
    if ([string]::IsNullOrWhiteSpace([string]$script:State.WebAppResourceId)) { throw 'Run menu 6 first.' }
    if (-not (Confirm-ExactText -Prompt 'This ZIP-deploys the generated portal code and restarts the Web App.' -Expected ("PUBLISH-{0}" -f $script:State.WebAppName))) {
        Write-Log 'Code deployment cancelled.' 'WARN'; return
    }
    Write-Log 'Publishing portal ZIP. App Service builds Python dependencies during deployment.' 'STEP'
    Publish-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName -ArchivePath $package -Force | Out-Null
    Restart-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName | Out-Null
    $script:State.LastDeploymentUtc=Get-UtcNowText
    Save-State
    Write-Log ("Portal package deployed: https://{0}" -f $script:State.WebAppHostName) 'OK'
}

function Test-PortalDeployment {
    Assert-AzConnected; Assert-GraphConnected; Assert-Configuration
    Write-Log 'Validating Azure resources, Flask routes and complete Easy Auth linkage...' 'STEP'
    $web=Get-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName -ErrorAction Stop
    $settings=Get-WebAppSettingsHashtable -ResourceGroup $script:State.ResourceGroupName -Name $script:State.WebAppName
    $requiredSettings=@('SCM_DO_BUILD_DURING_DEPLOYMENT','PIM_PORTAL_MODE','PIM_DB_PATH','PIM_ROLE_ALLOWLIST','FLASK_SECRET_KEY','MICROSOFT_PROVIDER_AUTHENTICATION_SECRET')
    $missing=@($requiredSettings | Where-Object {-not $settings.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$settings[$_])})
    $auth=Invoke-Arm GET ("{0}/config/authsettingsV2?api-version=2023-12-01" -f $script:State.WebAppResourceId)
    $aad=$auth.properties.identityProviders.azureActiveDirectory; $reg=$aad.registration
    $expectedClientId=[string]$script:State.AuthApplicationClientId
    $expectedIssuer=("https://login.microsoftonline.com/{0}/v2.0" -f $script:State.TenantId)
    $expectedRedirect=("https://{0}/.auth/login/aad/callback" -f $script:State.WebAppHostName)
    $secretName=[string]$reg.clientSecretSettingName
    $appRead=$null; $redirectPresent=$false; $credentialCount=0
    if(-not [string]::IsNullOrWhiteSpace([string]$script:State.AuthApplicationObjectId)){
        $appRead=Invoke-Graph GET ("/applications/{0}?`$select=id,appId,signInAudience,web,passwordCredentials" -f $script:State.AuthApplicationObjectId)
        $redirectPresent=@($appRead.web.redirectUris) -contains $expectedRedirect
        $credentialCount=@($appRead.passwordCredentials | Where-Object {(Get-Date $_.endDateTime).ToUniversalTime() -gt (Get-Date).ToUniversalTime()}).Count
    }
    $authChecks=[ordered]@{
        PlatformEnabled=[bool]$auth.properties.platform.enabled
        ProviderEnabled=[bool]$aad.enabled
        RequireAuthentication=[bool]$auth.properties.globalValidation.requireAuthentication
        ClientIdMatches=([string]$reg.clientId -eq $expectedClientId -and [string]$appRead.appId -eq $expectedClientId)
        IssuerMatches=(([string]$reg.openIdIssuer).TrimEnd('/') -eq $expectedIssuer.TrimEnd('/'))
        SecretSettingNameMatches=($secretName -eq 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET')
        SecretSettingHasValue=($settings.ContainsKey($secretName) -and -not [string]::IsNullOrWhiteSpace([string]$settings[$secretName]))
        RedirectUriPresent=$redirectPresent
        ValidPasswordCredentialPresent=($credentialCount -gt 0)
        SingleTenant=([string]$appRead.signInAudience -eq 'AzureADMyOrg')
        IdTokenIssuanceEnabled=[bool]$appRead.web.implicitGrantSettings.enableIdTokenIssuance
        ImplicitAccessTokenDisabled=(-not [bool]$appRead.web.implicitGrantSettings.enableAccessTokenIssuance)
    }
    $metadataUrl=("{0}/.well-known/openid-configuration" -f $expectedIssuer)
    $metadataStatus='Unknown';$metadataIssuer=$null;$metadataAuthorizationEndpoint=$null;$metadataTokenEndpoint=$null
    try{$metadataResponse=Invoke-WebRequest -Uri $metadataUrl -UseBasicParsing -TimeoutSec 30;$metadataStatus=[string]$metadataResponse.StatusCode;$metadata=([string]$metadataResponse.Content)|ConvertFrom-Json;$metadataIssuer=[string]$metadata.issuer;$metadataAuthorizationEndpoint=[string]$metadata.authorization_endpoint;$metadataTokenEndpoint=[string]$metadata.token_endpoint}catch{$metadataStatus=$_.Exception.Message}
    $authChecks['OpenIdMetadataHttp200']=($metadataStatus -eq '200')
    $authChecks['MetadataAuthorizationEndpointPresent']=(-not [string]::IsNullOrWhiteSpace($metadataAuthorizationEndpoint))
    $authChecks['MetadataTokenEndpointPresent']=(-not [string]::IsNullOrWhiteSpace($metadataTokenEndpoint))
    $baseUrl=("https://{0}" -f $script:State.WebAppHostName);$healthUrl="$baseUrl/health";$manifestUrl="$baseUrl/route-manifest"
    $healthStatus='Unknown';$healthBody=$null;$manifestStatus='Unknown';$manifestObject=$null
    for($i=0;$i -lt 12;$i++){try{$r=Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 30;$healthStatus=[string]$r.StatusCode;$healthBody=[string]$r.Content;if($r.StatusCode -eq 200){break}}catch{$healthStatus=$_.Exception.Message};Start-Sleep 10}
    try{$mr=Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing -TimeoutSec 30;$manifestStatus=[string]$mr.StatusCode;if($mr.StatusCode -eq 200){$manifestObject=([string]$mr.Content)|ConvertFrom-Json}}catch{$manifestStatus=$_.Exception.Message}
    $expectedRoutes=@('/','/health','/route-manifest','/requests','/requests/new','/approvals','/pim','/activation','/expiry','/audit','/settings')
    $deployedRoutes=@();if($null -ne $manifestObject){$deployedRoutes=@($manifestObject.routes|ForEach-Object{[string]$_.path})};$missingRoutes=@($expectedRoutes|Where-Object{$deployedRoutes -notcontains $_})
    $healthVersion=$null;try{$healthVersion=[string](($healthBody|ConvertFrom-Json).version)}catch{}
    $authFailures=@($authChecks.GetEnumerator()|Where-Object{-not [bool]$_.Value}|ForEach-Object{$_.Key})
    $mi=[string]$web.Identity.PrincipalId
    $pass=($web.State -eq 'Running' -and $missing.Count -eq 0 -and $healthStatus -eq '200' -and $healthVersion -eq $script:LauncherVersion -and $manifestStatus -eq '200' -and $missingRoutes.Count -eq 0 -and $authFailures.Count -eq 0)
    $validation=[pscustomobject]@{ValidatedUtc=Get-UtcNowText;WebAppState=$web.State;DefaultHostName=$web.DefaultHostName;ManagedIdentityObjectId=$mi;MissingAppSettings=$missing;HealthStatus=$healthStatus;HealthVersion=$healthVersion;RouteManifestStatus=$manifestStatus;DeployedRouteCount=$deployedRoutes.Count;MissingRequiredRoutes=$missingRoutes;AuthApplicationClientId=$expectedClientId;AuthIssuer=[string]$reg.openIdIssuer;OpenIdMetadataUrl=$metadataUrl;OpenIdMetadataStatus=$metadataStatus;MetadataIssuer=$metadataIssuer;MetadataAuthorizationEndpoint=$metadataAuthorizationEndpoint;MetadataTokenEndpoint=$metadataTokenEndpoint;IdTokenIssuanceEnabled=[bool]$appRead.web.implicitGrantSettings.enableIdTokenIssuance;AuthSecretSettingName=$secretName;ExpectedRedirectUri=$expectedRedirect;ValidPasswordCredentialCount=$credentialCount;AuthenticationChecks=$authChecks;AuthenticationFailures=$authFailures;PortalMode=$settings['PIM_PORTAL_MODE'];LastDeploymentUtc=$script:State.LastDeploymentUtc;Result=if($pass){'PASS'}else{'FAIL'}}
    Ensure-Directory;$path=Join-Path $OutputRoot ('Validation-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'));$validation|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $path -Encoding UTF8;$script:State.LastValidationUtc=Get-UtcNowText;Save-State;$validation|Format-List
    if($pass){Write-Log "Deep deployment and Easy Auth validation passed: $path" 'OK'}else{Write-Log "Validation failed. AuthenticationFailures=$($authFailures -join ', '); MissingRoutes=$($missingRoutes -join ', '): $path" 'ERROR'}
}

function Show-CustomerDemoRunbook {
    Assert-Configuration
    $base="https://$($script:State.WebAppName).azurewebsites.net"
@"
===============================================================================
 Customer Demo Runbook
===============================================================================
Portal                $base
Health                $base/health
1. Dashboard           $base/
2. PIM Request         $base/requests/new
3. Approval Inbox      $base/approvals
4. Role Assignment     $base/pim
5. PIM Activation      $base/activation
6. Expiry / Revoke     $base/expiry
7. Audit / Evidence    $base/audit
8. Settings / Health   $base/settings

Recommended live narration
A. Create sample request: dedicated admin UPN / User Administrator / 30 days / 4 hours.
B. Approve SystemOwner, Security and SoD gates.
C. Execute Eligible. Explain Active -> Eligible -> Pending duplicate checks.
D. Sync Graph status if targetScheduleId is not immediately returned.
E. Open PIM My roles and activate according to the role policy.
F. Show expiry timestamp and scoped revoke for the Portal-owned schedule.
G. Export Evidence ZIP and verify SHA256-MANIFEST.csv.

Portal mode: $($script:State.PortalMode)
- Simulation: no Graph changes.
- Live: actual Entra PIM eligibility write; verify managed identity permissions first.
===============================================================================
"@ | Write-Host
}

function Export-LauncherEvidence {
    Assert-AzConnected; Assert-Configuration
    Ensure-Directory
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'; $dir=Join-Path $OutputRoot ("Launcher-Evidence-$stamp")
    [void](New-Item -Path $dir -ItemType Directory -Force)
    $script:State | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $dir 'launcher-state.json') -Encoding UTF8
    if(-not [string]::IsNullOrWhiteSpace([string]$script:State.WhatIfPlanPath) -and (Test-Path $script:State.WhatIfPlanPath)) {
        Copy-Item $script:State.WhatIfPlanPath (Join-Path $dir 'whatif-deployment-plan.json') -Force
    }
    try {
        $web=Get-AzWebApp -ResourceGroupName $script:State.ResourceGroupName -Name $script:State.WebAppName
        [pscustomobject]@{Name=$web.Name;State=$web.State;DefaultHostName=$web.DefaultHostName;HttpsOnly=$web.HttpsOnly;ResourceId=$web.Id;ManagedIdentityObjectId=$web.Identity.PrincipalId} |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $dir 'azure-webapp.json') -Encoding UTF8
    } catch { $_.Exception.Message | Set-Content (Join-Path $dir 'azure-webapp-error.txt') -Encoding UTF8 }
    @($script:State.GraphAppRoleAssignments) | Export-Csv (Join-Path $dir 'launcher-created-graph-app-role-assignments.csv') -NoTypeInformation -Encoding UTF8
    $files=Get-ChildItem $dir -File
    $manifest=foreach($f in $files){$h=Get-FileHash $f.FullName -Algorithm SHA256;[pscustomobject]@{File=$f.Name;SHA256=$h.Hash;Length=$f.Length}}
    $manifest | Export-Csv (Join-Path $dir 'SHA256-MANIFEST.csv') -NoTypeInformation -Encoding UTF8
    $zip="$dir.zip"; Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zip -Force
    $script:State.EvidenceFiles=@($script:State.EvidenceFiles)+@($zip); Save-State
    Write-Log "Launcher evidence package exported: $zip" 'OK'
}

function Show-LauncherState {
    $script:State | ConvertTo-Json -Depth 30 | Write-Host
}

function Get-CleanupPlan {
    $graphAssignments=@($script:State.GraphAppRoleAssignments)
    $resources=@($script:State.CreatedResources)
    [pscustomobject]@{
        GeneratedUtc=Get-UtcNowText; Execution='No change - cleanup preview only'
        ManagedIdentityGraphAssignments=$graphAssignments
        AuthenticationServicePrincipalId=$script:State.AuthServicePrincipalObjectId
        AuthenticationApplicationObjectId=$script:State.AuthApplicationObjectId
        AzureResources=$resources
        ResourceGroupCreatedByLauncher=[bool]$script:State.ResourceGroupCreatedByLauncher
        ResourceGroupAction=if([bool]$script:State.ResourceGroupCreatedByLauncher){'Delete tracked dedicated resource group'}else{'Preserve resource group; delete only tracked resources in reverse order'}
        PortalPimBoundary='Portal PIM schedules are not bulk-deleted here. Use each portal ticket scoped revoke before infrastructure cleanup.'
    }
}

function Show-CleanupPreview {
    $plan=Get-CleanupPlan
    $plan | ConvertTo-Json -Depth 30 | Write-Host
    Ensure-Directory
    $path=Join-Path $OutputRoot ('Cleanup-Preview-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Log "Cleanup preview exported: $path" 'OK'
}

function Remove-LauncherTrackedObjects {
    Assert-AzConnected; Assert-GraphConnected
    $plan=Get-CleanupPlan
    Write-Host ($plan | ConvertTo-Json -Depth 30) -ForegroundColor Yellow
    Write-Host 'Before infrastructure cleanup, revoke any live Portal-owned eligibility from the portal if required.' -ForegroundColor Red
    if(-not (Confirm-ExactText -Prompt 'This removes only state-tracked deployment objects. Existing/non-owned PIM eligibilities are not bulk-deleted.' -Expected ("DELETE-TRACKED-{0}" -f $AssetPrefix))) {
        Write-Log 'Cleanup cancelled.' 'WARN'; return
    }

    Ensure-Directory
    $archive=Join-Path $OutputRoot ('PreCleanup-State-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $script:State | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $archive -Encoding UTF8

    $mi=[string]$script:State.WebAppManagedIdentityObjectId
    foreach($assignment in @($script:State.GraphAppRoleAssignments)) {
        try {
            if(-not [string]::IsNullOrWhiteSpace($mi) -and -not [string]::IsNullOrWhiteSpace([string]$assignment.AssignmentId)) {
                Invoke-Graph DELETE ("/servicePrincipals/{0}/appRoleAssignments/{1}" -f $mi,$assignment.AssignmentId) | Out-Null
                Write-Log ("Removed managed identity Graph role: {0}" -f $assignment.Permission) 'OK'
            }
        } catch { Write-Log ("Graph role cleanup failed for {0}: {1}" -f $assignment.Permission,$_.Exception.Message) 'WARN' }
    }

    if(-not [string]::IsNullOrWhiteSpace([string]$script:State.AuthServicePrincipalObjectId)) {
        try { Invoke-Graph DELETE ("/servicePrincipals/{0}" -f $script:State.AuthServicePrincipalObjectId) | Out-Null; Write-Log 'Tracked authentication service principal removed.' 'OK' }
        catch { Write-Log ("Authentication service principal cleanup: {0}" -f $_.Exception.Message) 'WARN' }
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$script:State.AuthApplicationObjectId)) {
        try { Invoke-Graph DELETE ("/applications/{0}" -f $script:State.AuthApplicationObjectId) | Out-Null; Write-Log 'Tracked authentication application removed.' 'OK' }
        catch { Write-Log ("Authentication application cleanup: {0}" -f $_.Exception.Message) 'WARN' }
    }

    if([bool]$script:State.ResourceGroupCreatedByLauncher) {
        $rg=Get-AzResourceGroup -Name $script:State.ResourceGroupName -ErrorAction SilentlyContinue
        if($rg){ Remove-AzResourceGroup -Name $script:State.ResourceGroupName -Force | Out-Null; Write-Log 'Launcher-created dedicated resource group deletion submitted.' 'OK' }
    } else {
        $ordered=@($script:State.CreatedResources | Sort-Object @{Expression={if($_.Type -eq 'Microsoft.Web/sites'){1}elseif($_.Type -eq 'Microsoft.Web/serverfarms'){2}else{3}}})
        foreach($resource in $ordered) {
            if($resource.Type -eq 'Microsoft.Resources/resourceGroups'){continue}
            try {
                $existing=Get-AzResource -ResourceId $resource.Id -ErrorAction SilentlyContinue
                if($existing){Remove-AzResource -ResourceId $resource.Id -Force | Out-Null;Write-Log ("Removed tracked resource: {0}" -f $resource.Name) 'OK'}
            } catch { Write-Log ("Resource cleanup failed for {0}: {1}" -f $resource.Name,$_.Exception.Message) 'WARN' }
        }
    }

    $script:State=New-InitialState
    Save-State
    Write-Log "Cleanup completed. Pre-cleanup state archived: $archive" 'OK'
}

function Show-Menu {
    Clear-Host
    Write-Host '================================================================================'
    Write-Host ' Entra PIM + Internal ITSM Financial Portal Launcher v2.0.5.1'
    Write-Host ' Azure App Service Sample Cloud Operations Portal | Safe default: Simulation'
    Write-Host '================================================================================'
    Write-Host '[P]  Prerequisite/module check/install                 Role: Local admin optional'
    Write-Host '[1]  Operating model, architecture and API boundary   Role: Read-only'
    Write-Host '[2]  Connect Azure + Microsoft Graph                   Role: Setup operator / PRA'
    Write-Host '[3]  Configure tenant, subscription and demo values   Role: Demo operator'
    Write-Host '[4]  Generate Flask portal source + deployment ZIP    Role: Local read-only'
    Write-Host '[5]  WhatIf deployment and duplicate assessment       Role: Azure/Graph reader'
    Write-Host '[6]  Deploy App Service, Web App and Managed Identity Role: Contributor'
    Write-Host '[7]  Repair Entra App ID token + Easy Auth v2      Role: App admin + Contributor'
    Write-Host '[8]  GRANT MI Graph roles + switch to LIVE PIM        Role: Privileged admin'
    Write-Host '[9]  ZIP deploy portal application                    Role: Web App Contributor'
    Write-Host '[10] Deep validate OIDC, ID token, routes and health              Role: Reader'
    Write-Host '[11] Show customer demo runbook and portal paths      Role: Read-only'
    Write-Host '[12] Export launcher evidence + SHA-256 manifest      Role: Reader/Audit'
    Write-Host '[13] Show local launcher state                        Role: Local read-only'
    Write-Host '[90] Cleanup preview (no change)                      Role: Read-only'
    Write-Host '[99] Remove launcher-tracked deployment objects       Role: Owner/App admin'
    Write-Host '[0]  Exit'
    Write-Host '--------------------------------------------------------------------------------'
    Write-Host ("State: Mode={0}; RG={1}; WebApp={2}" -f $script:State.PortalMode,$script:State.ResourceGroupName,$script:State.WebAppName) -ForegroundColor DarkCyan
}

Load-State
while($true) {
    Show-Menu
    $choice=Read-Host 'Select menu'
    try {
        switch($choice) {
            'P' { Test-Prerequisites; Pause-Menu }
            'p' { Test-Prerequisites; Pause-Menu }
            '1' { Show-OperatingModel; Pause-Menu }
            '2' { Connect-DemoServices; Pause-Menu }
            '3' { Set-DemoConfiguration; Pause-Menu }
            '4' { New-PortalSource; Pause-Menu }
            '5' { New-WhatIfDeploymentPlan; Pause-Menu }
            '6' { Deploy-AzureInfrastructure; Pause-Menu }
            '7' { Configure-AppServiceAuthentication; Pause-Menu }
            '8' { Grant-ManagedIdentityGraphPermissions; Pause-Menu }
            '9' { Deploy-PortalPackage; Pause-Menu }
            '10' { Test-PortalDeployment; Pause-Menu }
            '11' { Show-CustomerDemoRunbook; Pause-Menu }
            '12' { Export-LauncherEvidence; Pause-Menu }
            '13' { Show-LauncherState; Pause-Menu }
            '90' { Show-CleanupPreview; Pause-Menu }
            '99' { Remove-LauncherTrackedObjects; Pause-Menu }
            '0' { break }
            default { Write-Log 'Invalid menu.' 'WARN'; Pause-Menu }
        }
        if($choice -eq '0'){break}
    } catch {
        Write-Log $_.Exception.Message 'ERROR'
        if($null -ne $_.ScriptStackTrace){Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray}
        Pause-Menu
    }
}
