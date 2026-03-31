# glue

VLESS+XTLS-REALITY proxy server setup for censorship circumvention.

## Deploy

```bash
scp glue.sh root@YOUR_SERVER_IP:/root/
ssh root@YOUR_SERVER_IP
chmod +x glue.sh
./glue.sh install nobitex.ir
```

## Commands

```bash
./glue.sh install <sni>   # Install and configure (run once)
./glue.sh list            # Show VLESS links to share with clients
./glue.sh status          # Live monitor — connections, bandwidth, errors
```

## Client setup

Import any of the `vless://` links into **NapsternetV (NPV Tunnel)** via clipboard.
Share links over Signal.

## SNI tips

Pick a domain Iran wouldn't block — a major Iranian bank or government-adjacent site works well.
The SNI must support TLS 1.3 and be reachable on port 443 from your server.