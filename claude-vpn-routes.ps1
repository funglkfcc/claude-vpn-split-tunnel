#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Route only Claude/Anthropic traffic through Surfshark VPN.
.DESCRIPTION
    Resolves Claude/Anthropic domains to IPs, finds the Surfshark VPN adapter,
    and adds persistent routes so only that traffic flows through the VPN tunnel.
    All other traffic uses the default gateway (no VPN).
.PARAMETER Action
    "add" to create routes, "remove" to delete them, "status" to show current routes.
#>

param(
    [ValidateSet("add", "remove", "status")]
    [string]$Action = "add"
)

$ErrorActionPreference = "Stop"

# --- Claude/Anthropic domains to route through VPN ---
$domains = @(
    "claude.ai",
    "www.claude.ai",
    "api.anthropic.com",
    "anthropic.com",
    "www.anthropic.com",
    "console.anthropic.com",
    "cdn.anthropic.com",
    "statsig.anthropic.com",
    "sentry.anthropic.com"
)

# --- Known Anthropic IP CIDR blocks (AS394354 / AS396982) ---
# These cover ranges that DNS alone might miss (CDN edge nodes rotate).
$staticCidrs = @(
    "160.79.104.0/23",
    "2607:6bc0::/48"
)

function Get-SurfsharkAdapter {
    $adapter = Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -match "Surfshark|WireGuard|Wintun|TAP-Surfshark|OpenVPN" -and
        $_.Status -eq "Up"
    } | Select-Object -First 1

    if (-not $adapter) {
        Write-Error "No active Surfshark VPN adapter found. Make sure Surfshark is connected first."
        exit 1
    }
    return $adapter
}

function Get-VpnGateway {
    param([int]$InterfaceIndex)

    $route = Get-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
             Select-Object -First 1

    if ($route) {
        return $route.NextHop
    }

    # Fallback: use the first IPv4 address on the adapter and guess .1 gateway
    $ip = Get-NetIPAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Select-Object -First 1
    if ($ip) {
        $parts = $ip.IPAddress -split "\."
        $parts[3] = "1"
        return ($parts -join ".")
    }

    Write-Error "Cannot determine VPN gateway for interface index $InterfaceIndex"
    exit 1
}

function Resolve-DomainsToIPs {
    $ips = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($domain in $domains) {
        try {
            $records = [System.Net.Dns]::GetHostAddresses($domain)
            foreach ($r in $records) {
                if ($r.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    [void]$ips.Add($r.IPAddressToString)
                }
            }
        } catch {
            Write-Warning "Could not resolve $domain — skipping"
        }
    }
    return $ips
}

function Show-Status {
    Write-Host "`n=== Current Anthropic/Claude routes ===" -ForegroundColor Cyan
    $found = $false
    foreach ($ip in (Resolve-DomainsToIPs)) {
        $existing = Get-NetRoute -DestinationPrefix "$ip/32" -ErrorAction SilentlyContinue
        if ($existing) {
            $found = $true
            foreach ($r in $existing) {
                $adapterName = (Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue).Name
                Write-Host "  $ip -> $($r.NextHop) via $adapterName (ifIndex $($r.InterfaceIndex))"
            }
        }
    }
    if (-not $found) {
        Write-Host "  No Claude-specific routes found." -ForegroundColor Yellow
    }

    Write-Host "`n=== VPN adapter ===" -ForegroundColor Cyan
    $vpnAdapters = Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -match "Surfshark|WireGuard|Wintun|TAP-Surfshark|OpenVPN"
    }
    if ($vpnAdapters) {
        foreach ($a in $vpnAdapters) {
            Write-Host "  $($a.Name) [$($a.InterfaceDescription)] — $($a.Status)"
        }
    } else {
        Write-Host "  No Surfshark adapter detected." -ForegroundColor Yellow
    }
}

function Add-ClaudeRoutes {
    $adapter = Get-SurfsharkAdapter
    $gateway = Get-VpnGateway -InterfaceIndex $adapter.ifIndex
    $ifIndex = $adapter.ifIndex

    Write-Host "VPN adapter : $($adapter.Name) [$($adapter.InterfaceDescription)]" -ForegroundColor Green
    Write-Host "VPN gateway : $gateway" -ForegroundColor Green
    Write-Host "Interface   : $ifIndex`n" -ForegroundColor Green

    # Remove all VPN catch-all routes so non-Claude traffic skips the VPN.
    # Surfshark uses 0.0.0.0/1 + 128.0.0.0/1 (split-route trick) instead of 0.0.0.0/0.
    $catchAllPrefixes = @("0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1")
    foreach ($prefix in $catchAllPrefixes) {
        $route = Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix $prefix -ErrorAction SilentlyContinue
        if ($route) {
            Write-Host "Removing VPN catch-all route ($prefix) so only Claude traffic uses VPN..." -ForegroundColor Yellow
            Remove-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix $prefix -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    # Resolve domains and add /32 routes
    $ips = Resolve-DomainsToIPs
    Write-Host "Resolved $($ips.Count) unique IPs from $($domains.Count) domains:`n"

    $added = 0
    foreach ($ip in $ips) {
        $prefix = "$ip/32"
        $existing = Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue |
                    Where-Object { $_.InterfaceIndex -eq $ifIndex }
        if ($existing) {
            Write-Host "  [skip] $prefix — route already exists" -ForegroundColor DarkGray
            continue
        }
        try {
            New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $ifIndex -NextHop $gateway -RouteMetric 1 -ErrorAction Stop | Out-Null
            Write-Host "  [add]  $prefix -> $gateway" -ForegroundColor Green
            $added++
        } catch {
            Write-Warning "  [fail] $prefix — $($_.Exception.Message)"
        }
    }

    # Add static CIDR blocks
    foreach ($cidr in $staticCidrs) {
        if ($cidr -match ":") { continue } # skip IPv6 for now
        $existing = Get-NetRoute -DestinationPrefix $cidr -ErrorAction SilentlyContinue |
                    Where-Object { $_.InterfaceIndex -eq $ifIndex }
        if ($existing) {
            Write-Host "  [skip] $cidr — route already exists" -ForegroundColor DarkGray
            continue
        }
        try {
            New-NetRoute -DestinationPrefix $cidr -InterfaceIndex $ifIndex -NextHop $gateway -RouteMetric 1 -ErrorAction Stop | Out-Null
            Write-Host "  [add]  $cidr -> $gateway" -ForegroundColor Green
            $added++
        } catch {
            Write-Warning "  [fail] $cidr — $($_.Exception.Message)"
        }
    }

    Write-Host "`nDone. Added $added route(s). Only Claude/Anthropic traffic will use the VPN." -ForegroundColor Cyan
    Write-Host "Run with -Action remove to clean up, or -Action status to check." -ForegroundColor DarkGray
}

function Remove-ClaudeRoutes {
    $ips = Resolve-DomainsToIPs
    $removed = 0

    foreach ($ip in $ips) {
        $prefix = "$ip/32"
        $existing = Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-NetRoute -DestinationPrefix $prefix -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  [del] $prefix" -ForegroundColor Yellow
            $removed++
        }
    }
    foreach ($cidr in $staticCidrs) {
        if ($cidr -match ":") { continue }
        $existing = Get-NetRoute -DestinationPrefix $cidr -ErrorAction SilentlyContinue
        if ($existing) {
            Remove-NetRoute -DestinationPrefix $cidr -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "  [del] $cidr" -ForegroundColor Yellow
            $removed++
        }
    }

    Write-Host "`nRemoved $removed route(s)." -ForegroundColor Cyan
}

# --- Main ---
switch ($Action) {
    "add"    { Add-ClaudeRoutes }
    "remove" { Remove-ClaudeRoutes }
    "status" { Show-Status }
}
