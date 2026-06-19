# Claude-Only VPN Routing

Routes only Claude/Anthropic traffic through Surfshark VPN. All other traffic bypasses the VPN.

## Prerequisites

- Surfshark VPN installed and connected
- PowerShell running as Administrator

## Important: Surfshark Setup

Before running the script, configure Surfshark to NOT route all traffic by default:

1. Open Surfshark → Settings → VPN settings
2. Set **Protocol** to **WireGuard** (recommended — creates a clear adapter)
3. Connect to your preferred server

The script will remove the VPN's default route (0.0.0.0/0) and add specific routes
only for Claude/Anthropic IPs.

## Usage

```powershell
# Run as Administrator

# Add routes (only Claude traffic goes through VPN)
.\claude-vpn-routes.ps1 -Action add

# Check current routes
.\claude-vpn-routes.ps1 -Action status

# Remove routes (cleanup)
.\claude-vpn-routes.ps1 -Action remove
```

## What gets routed through VPN

- claude.ai and subdomains
- api.anthropic.com
- anthropic.com and subdomains
- Anthropic's known IP ranges (AS394354)

## Notes

- Routes are non-persistent — they reset on reboot or VPN reconnect.
- Re-run `-Action add` after reconnecting Surfshark.
- DNS resolution happens at script run time; if Anthropic's CDN IPs rotate,
  re-run the script to pick up new addresses.
