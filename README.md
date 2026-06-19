# Split-Tunnel VPN for Claude

Route **only** Claude/Anthropic traffic through Surfshark VPN using WireGuard. All other traffic goes through your normal internet connection — no speed penalty, no Surfshark desktop app needed.

## How It Works

WireGuard's `AllowedIPs` setting controls which traffic enters the VPN tunnel. By setting it to Anthropic's IP range (`160.79.104.0/23`), only Claude traffic is routed through the VPN. Everything else bypasses it entirely.

## Prerequisites

- Active **Surfshark** subscription
- **Windows 10/11**

## Setup

### 1. Install WireGuard

Download and install the standalone WireGuard client from [wireguard.com/install](https://www.wireguard.com/install/).

This is **not** Surfshark's built-in WireGuard — it's the official standalone client.

### 2. Get Surfshark WireGuard Credentials

1. Log in to [my.surfshark.com](https://my.surfshark.com/)
2. Go to **VPN → Manual Setup → Router → WireGuard**
3. Click **Generate New Key Pair**
4. Note down:
   - **Private Key**
   - **Server Public Key**
   - **Server Address** (pick a server, e.g. `uk-lon.prod.surfshark.com`)

### 3. Create the Config File

Create a file called `claude-only.conf` with the following content:

```ini
[Interface]
Address = 10.14.0.2/16
PrivateKey = <your-private-key>

[Peer]
PublicKey = <server-public-key>
Endpoint = <server-address>:51820
AllowedIPs = 160.79.104.0/23
PersistentKeepalive = 25
```

Replace the three `<...>` placeholders with your credentials from Step 2.

**Important:** Do **not** add a `DNS` line. Adding VPN DNS servers breaks split tunneling because those DNS IPs aren't in `AllowedIPs`, making DNS queries fail.

### 4. Import and Activate

1. Open the **WireGuard** app
2. Click **Import tunnel(s) from file**
3. Select your `claude-only.conf`
4. Click **Activate**

That's it — Claude traffic now goes through the VPN.

## Verify It Works

Open a terminal and run:

```
tracert -d -h 5 claude.ai
tracert -d -h 5 google.com
```

- **claude.ai** should show VPN hops (different from your normal route)
- **google.com** should show your normal ISP hops

## What Gets Routed Through VPN

| Destination | Routed? |
|---|---|
| claude.ai | Through VPN |
| api.anthropic.com | Through VPN |
| anthropic.com | Through VPN |
| Everything else | Direct (no VPN) |

All these resolve to IPs within `160.79.104.0/23` (Anthropic's address space).

## Troubleshooting

| Problem | Solution |
|---|---|
| All traffic goes through VPN | Remove the `DNS` line from the config |
| Claude doesn't load | Check the tunnel is active (green indicator in WireGuard). Try a different Surfshark server |
| Can't connect at all | Regenerate your key pair on Surfshark's manual setup page |
| Connection drops | Add `PersistentKeepalive = 25` to the `[Peer]` section |

## Security Note

Your `claude-only.conf` contains your VPN private key. Keep it safe:
- Do **not** commit it to git (`.gitignore` excludes `*.conf`)
- If your key is ever exposed, regenerate it immediately on Surfshark's manual setup page
