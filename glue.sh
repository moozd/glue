#!/bin/bash

set -e

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

CONFIG="/usr/local/etc/xray/config.json"
NGINX_SITE="/etc/nginx/sites-available/xray-fallback"
OUTPUT_FILE="$HOME/vless-links.txt"

# ─── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run as root"

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    echo -e ""
    echo -e "${BOLD}Usage:${NC} $0 <command> [options]"
    echo -e ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${CYAN}install <sni>${NC}         Install Xray + Nginx and configure with given SNI domain"
    echo -e "  ${CYAN}harden [ssh-port]${NC}    Harden server: UFW firewall + non-standard SSH port"
    echo -e "  ${CYAN}list${NC}                 Show existing VLESS configs and links"
    echo -e "  ${CYAN}status${NC}               Live monitor — connected clients, bandwidth, errors"
    echo -e ""
    echo -e "${BOLD}Examples:${NC}"
    echo -e "  $0 install nobitex.ir"
    echo -e "  $0 harden 2222"
    echo -e "  $0 list"
    echo -e "  $0 status"
    echo -e ""
    exit 1
}

# ─── Command: list ────────────────────────────────────────────────────────────
cmd_list() {
    if [[ -f "$OUTPUT_FILE" ]]; then
        echo ""
        cat "$OUTPUT_FILE"
        exit 0
    elif [[ -f "$CONFIG" ]]; then
        warn "No saved links file found. Reading from config..."
        SERVER_IP=$(curl -s https://api.ipify.org)
        SNI=$(grep -o '"dest": "[^"]*"' "$CONFIG" | head -1 | cut -d'"' -f4 | cut -d: -f1)
        SHORT_ID=$(grep -o '"shortIds": \["[^"]*"' "$CONFIG" | grep -o '"[^"]*"$' | tr -d '"')
        UUIDS=($(grep -o '"id": "[^"]*"' "$CONFIG" | cut -d'"' -f4))
        PUBLIC_KEY=$(grep -o '"pbk=[^&]*"' "$OUTPUT_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || echo "unknown — rerun install to regenerate")
        BASE="security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp"
        echo ""
        echo "========================================================"
        echo "  Server IP  : $SERVER_IP"
        echo "  SNI        : $SNI"
        echo "  Short ID   : $SHORT_ID"
        echo "========================================================"
        echo ""
        for i in "${!UUIDS[@]}"; do
            echo "Link $((i+1)):"
            echo "  vless://${UUIDS[$i]}@${SERVER_IP}:443?${BASE}#REALITY-$((i+1))"
            echo ""
        done
        exit 0
    else
        error "No existing config found. Run: $0 install <sni-domain>"
    fi
}

# ─── Command: status ──────────────────────────────────────────────────────────
cmd_status() {
    clear
    tput civis
    trap 'tput cnorm; echo ""; exit' INT TERM

    while true; do
        NOW=$(date '+%Y-%m-%d %H:%M:%S')
        SERVER_IP=$(hostname -I | awk '{print $1}')
        SNI=$(grep -o '"dest": "[^"]*"' "$CONFIG" 2>/dev/null | head -1 | cut -d'"' -f4 | cut -d: -f1)

        if systemctl is-active --quiet xray; then
            XRAY_STATUS="${GREEN}running${NC}"
        else
            XRAY_STATUS="${RED}STOPPED${NC}"
        fi

        if systemctl is-active --quiet nginx; then
            NGINX_STATUS="${GREEN}running${NC}"
        else
            NGINX_STATUS="${RED}STOPPED${NC}"
        fi

        CLIENTS=$(ss -tnp 2>/dev/null \
            | grep "xray" \
            | awk '$4 ~ /:443$/' \
            | awk '{print $5}' \
            | sed 's/::ffff://g' \
            | cut -d: -f1 \
            | sort | uniq -c | sort -rn)

        [[ -z "$CLIENTS" ]] && TOTAL=0 || TOTAL=$(echo "$CLIENTS" | grep -c '[0-9]')
        OUT_COUNT=$(ss -tnp 2>/dev/null | grep "xray" | awk '$4 !~ /:443$/' | wc -l)

        RX1=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null)
        TX1=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null)
        sleep 1
        RX2=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null)
        TX2=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null)
        RX_RATE=$(( (RX2 - RX1) / 1024 ))
        TX_RATE=$(( (TX2 - TX1) / 1024 ))

        BUF=""
        BUF+="\n"
        BUF+=" ${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}\n"
        BUF+=" ${BOLD}${CYAN}║           XRAY REALITY - LIVE MONITOR                ║${NC}\n"
        BUF+=" ${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}\n"
        BUF+="  ${BOLD}Time   :${NC} ${NOW}\n"
        BUF+="  ${BOLD}Server :${NC} ${SERVER_IP}\n"
        BUF+="  ${BOLD}Xray   :${NC} ${XRAY_STATUS}\n"
        BUF+="  ${BOLD}Nginx  :${NC} ${NGINX_STATUS} (fallback → 127.0.0.1:8080)\n"
        BUF+="  ${BOLD}SNI    :${NC} ${SNI:-unknown}\n"
        BUF+="\n"
        BUF+=" ${BOLD}${YELLOW} Connected Clients (${TOTAL} unique IPs)${NC}\n"
        BUF+="  ──────────────────────────────────────────────────────\n"
        BUF+="  ${BOLD}$(printf "%-6s  %-22s %-20s" "CONNS" "CLIENT IP" "HOSTNAME")${NC}\n"
        BUF+="  ──────────────────────────────────────────────────────\n"

        if [[ -z "$CLIENTS" || "$TOTAL" -eq 0 ]]; then
            BUF+="  ${RED}No active clients${NC}\n"
        else
            while read -r count ip; do
                [[ -z "$ip" ]] && continue
                HOST=$(timeout 1 dig +short -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//')
                [[ -z "$HOST" ]] && HOST="-"
                BUF+="  ${GREEN}$(printf "%-6s${NC}  %-22s %-20s" "$count" "$ip" "$HOST")\n"
            done <<< "$CLIENTS"
        fi

        BUF+="\n"
        BUF+=" ${BOLD}${YELLOW} Outbound Proxy Connections${NC}\n"
        BUF+="  ──────────────────────────────────────────────────────\n"
        BUF+="  Active outbound streams : ${CYAN}${OUT_COUNT}${NC}\n"
        BUF+="\n"
        BUF+=" ${BOLD}${YELLOW} Bandwidth (eth0)${NC}\n"
        BUF+="  ──────────────────────────────────────────────────────\n"
        BUF+="  ${GREEN}↓ IN ${NC} : ${RX_RATE} KB/s\n"
        BUF+="  ${CYAN}↑ OUT${NC} : ${TX_RATE} KB/s\n"
        BUF+="\n"
        BUF+=" ${BOLD}${YELLOW} Recent Errors / Failed Clients${NC}\n"
        BUF+="  ──────────────────────────────────────────────────────\n"

        ERRORS=$(tail -n 50 /var/log/xray/error.log 2>/dev/null \
            | grep -Ei "rejected|failed|invalid|error|warn|bad" \
            | tail -n 6)

        if [[ -z "$ERRORS" ]]; then
            BUF+="  ${GREEN}No recent errors${NC}\n"
        else
            while IFS= read -r line; do
                SHORT=$(echo "$line" | cut -c1-80)
                BUF+="  ${RED}${SHORT}${NC}\n"
            done <<< "$ERRORS"
        fi

        BUF+="\n"
        BUF+="  ${BOLD}Ctrl+C to exit${NC}\n"

        tput cup 0 0
        echo -ne "$BUF" | sed 's/$/\x1b[K/'
        printf '\033[J'
    done
}

# ─── Nginx fallback setup ─────────────────────────────────────────────────────
setup_nginx() {
    local SNI="$1"

    info "Installing Nginx..."
    apt-get install -y nginx -qq

    info "Configuring Nginx fallback on 127.0.0.1:8080..."
    cat > "$NGINX_SITE" << NGINXEOF
server {
    listen 127.0.0.1:8080;
    server_name ${SNI} www.${SNI};

    # Reverse-proxy to the real SNI site — probes get genuine content
    location / {
        proxy_pass https://${SNI};
        proxy_ssl_server_name on;
        proxy_ssl_name ${SNI};
        proxy_set_header Host ${SNI};
        proxy_set_header Accept-Encoding "";
        proxy_hide_header X-Powered-By;
        proxy_hide_header Server;

        # Don't forward client IP upstream
        proxy_set_header X-Real-IP "";
        proxy_set_header X-Forwarded-For "";

        # Cache upstream responses briefly to avoid hammering SNI on repeated probes
        proxy_cache xray_cache;
        proxy_cache_valid 200 5m;
    }

    access_log off;
    error_log  /var/log/nginx/xray-fallback.error.log warn;
}
NGINXEOF

    # Enable site
    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/xray-fallback
    rm -f /etc/nginx/sites-enabled/default

    # proxy_cache_path needed if proxy_cache_valid is used
    grep -q "proxy_cache_path" /etc/nginx/nginx.conf || \
        sed -i '/http {/a\\tproxy_cache_path /var/cache/nginx/xray levels=1:2 keys_zone=xray_cache:1m max_size=10m inactive=10m;' /etc/nginx/nginx.conf

    nginx -t -q || error "Nginx config test failed — check /etc/nginx/sites-available/xray-fallback"
    systemctl enable nginx --quiet
    systemctl restart nginx

    if ! systemctl is-active --quiet nginx; then
        error "Nginx failed to start — check: journalctl -u nginx -n 20"
    fi

    info "Nginx is serving fallback content on 127.0.0.1:8080"
}

# ─── Command: install ─────────────────────────────────────────────────────────
cmd_install() {
    local SNI="$1"
    [[ -z "$SNI" ]] && error "SNI domain required. Usage: $0 install <sni-domain>"

    # Strip protocol if included
    SNI=$(echo "$SNI" | sed 's|https\?://||' | sed 's|/.*||')

    # ── Verify SNI ────────────────────────────────────────────────────────────
    info "Verifying SNI: $SNI"

    if ! getent hosts "$SNI" > /dev/null 2>&1; then
        error "Cannot resolve $SNI — check the domain and try again"
    fi

    if ! timeout 5 bash -c "echo > /dev/tcp/$SNI/443" 2>/dev/null; then
        error "$SNI:443 is not reachable from this server"
    fi

    if ! echo | timeout 5 openssl s_client -connect "$SNI:443" 2>&1 | grep -q "TLSv1.3"; then
        error "$SNI does not support TLS 1.3 or is unreachable from this server (geo-blocked?). The SNI must be reachable FROM the VPS. Try: www.samsung.com, www.microsoft.com, www.apple.com"
    fi

    info "SNI verified: reachable and supports TLS 1.3"

    # ── Install dependencies ──────────────────────────────────────────────────
    info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y curl uuid-runtime openssl -qq

    # ── Install Xray ──────────────────────────────────────────────────────────
    if command -v xray &>/dev/null; then
        warn "Xray already installed: $(xray version 2>&1 | head -1) — skipping"
    else
        info "Installing Xray..."
        bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        info "Xray installed"
    fi

    # ── Generate keys ─────────────────────────────────────────────────────────
    info "Generating keys..."
    KEYS=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYS"  | grep "Password"   | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 8)
    SHORT_ID2=$(openssl rand -hex 4)
    SHORT_ID3=$(openssl rand -hex 6)
    SERVER_IP=$(curl -s https://api.ipify.org)

    UUIDS=()
    for i in {1..6}; do UUIDS+=("$(uuidgen)"); done

    CLIENTS_JSON=""
    for uuid in "${UUIDS[@]}"; do
        CLIENTS_JSON+="{\"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\"},"
    done
    CLIENTS_JSON="${CLIENTS_JSON%,}"

    # ── Write config ──────────────────────────────────────────────────────────
    info "Writing Xray config..."
    cat > "$CONFIG" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [${CLIENTS_JSON}],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "127.0.0.1:8080",
            "xver": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}", "www.${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}", "${SHORT_ID2}", "${SHORT_ID3}", ""]
        }
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private", "geoip:ir"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

    # ── Set up Nginx fallback ─────────────────────────────────────────────────
    setup_nginx "$SNI"

    # ── Start service ─────────────────────────────────────────────────────────
    info "Starting Xray service..."
    systemctl daemon-reload
    systemctl enable xray --quiet
    systemctl restart xray
    sleep 2

    if ! systemctl is-active --quiet xray; then
        error "Xray failed to start — check: journalctl -u xray -n 30"
    fi

    info "Xray is running on port 443"

    # ── Build and save links ──────────────────────────────────────────────────
    BASE="security=reality&encryption=none&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp"

    LINKS=()
    for i in "${!UUIDS[@]}"; do
        LINKS+=("vless://${UUIDS[$i]}@${SERVER_IP}:443?${BASE}#REALITY-$((i+1))")
    done

    {
        echo "VLESS+XTLS-REALITY Links"
        echo "Server: ${SERVER_IP} | SNI: ${SNI} | Port: 443"
        echo "Public Key: ${PUBLIC_KEY}"
        echo "Short ID:   ${SHORT_ID}"
        echo "========================================================"
        echo ""
        for i in "${!LINKS[@]}"; do
            echo "Link $((i+1)):"
            echo "${LINKS[$i]}"
            echo ""
        done
    } > "$OUTPUT_FILE"

    # ── Print results ─────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}========================================================"
    echo "  VLESS+XTLS-REALITY Setup Complete"
    echo -e "========================================================${NC}"
    echo -e "  ${BOLD}Nginx fallback${NC}: 127.0.0.1:8080 (serving /${SNI} page)"
    echo -e "  ${BOLD}Server IP${NC}  : $SERVER_IP"
    echo -e "  ${BOLD}SNI${NC}        : $SNI"
    echo -e "  ${BOLD}Public Key${NC} : $PUBLIC_KEY"
    echo -e "  ${BOLD}Short ID${NC}   : $SHORT_ID"
    echo ""
    for i in "${!LINKS[@]}"; do
        echo -e "${YELLOW}Link $((i+1)):${NC}"
        echo "  ${LINKS[$i]}"
        echo ""
    done
    echo -e "${GREEN}Saved to: $OUTPUT_FILE${NC}"
    echo ""
}

# ─── Command: harden ─────────────────────────────────────────────────────────
cmd_harden() {
    local NEW_SSH_PORT="${1:-}"

    # Pick a random port in the ephemeral range if none given
    if [[ -z "$NEW_SSH_PORT" ]]; then
        NEW_SSH_PORT=$(shuf -i 49152-65535 -n 1)
        warn "No SSH port specified — using random port: $NEW_SSH_PORT"
    fi

    # Validate port
    [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || error "Invalid port: $NEW_SSH_PORT"
    [[ "$NEW_SSH_PORT" -ge 1024 && "$NEW_SSH_PORT" -le 65535 ]] || error "Port must be between 1024 and 65535"

    # ── Install UFW ───────────────────────────────────────────────────────────
    info "Installing UFW..."
    apt-get install -y ufw -qq

    # ── Configure firewall BEFORE changing SSH port (avoid lockout) ──────────
    info "Configuring UFW rules..."
    ufw --force reset > /dev/null

    ufw default deny incoming
    ufw default allow outgoing

    # New SSH port
    ufw allow "${NEW_SSH_PORT}/tcp" comment "SSH"
    # Xray REALITY
    ufw allow 443/tcp comment "Xray REALITY"
    # Block everything else including old port 22 (already denied by default)

    ufw --force enable > /dev/null
    info "UFW enabled"

    # ── Harden SSH config ─────────────────────────────────────────────────────
    info "Updating SSH config..."
    local SSHD_CONF="/etc/ssh/sshd_config"

    # Change port
    if grep -q "^Port " "$SSHD_CONF"; then
        sed -i "s/^Port .*/Port ${NEW_SSH_PORT}/" "$SSHD_CONF"
    else
        echo "Port ${NEW_SSH_PORT}" >> "$SSHD_CONF"
    fi

    # Disable password auth — key-only from here on
    sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication no/" "$SSHD_CONF"
    # Disable challenge-response auth
    sed -i "s/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/" "$SSHD_CONF"
    # Reduce grace time
    grep -q "^LoginGraceTime" "$SSHD_CONF" \
        && sed -i "s/^LoginGraceTime.*/LoginGraceTime 30/" "$SSHD_CONF" \
        || echo "LoginGraceTime 30" >> "$SSHD_CONF"
    # Limit auth attempts
    grep -q "^MaxAuthTries" "$SSHD_CONF" \
        && sed -i "s/^MaxAuthTries.*/MaxAuthTries 3/" "$SSHD_CONF" \
        || echo "MaxAuthTries 3" >> "$SSHD_CONF"

    sshd -t || error "SSH config test failed — check $SSHD_CONF"
    # Service name differs by distro
    if systemctl list-units --type=service | grep -q "sshd.service"; then
        systemctl restart sshd
    else
        systemctl restart ssh
    fi

    # ── Print result ──────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}${BOLD}========================================================"
    echo "  Server Hardened"
    echo -e "========================================================${NC}"
    echo -e "  ${BOLD}New SSH port${NC}      : ${YELLOW}${NEW_SSH_PORT}${NC}"
    echo -e "  ${BOLD}Password auth${NC}     : disabled (key only)"
    echo -e "  ${BOLD}UFW${NC}               : enabled"
    echo -e "  ${BOLD}Allowed inbound${NC}   : ${NEW_SSH_PORT}/tcp (SSH), 443/tcp (Xray)"
    echo ""
    echo -e "  ${RED}${BOLD}IMPORTANT:${NC} Your next SSH command:"
    echo -e "  ${CYAN}ssh -p ${NEW_SSH_PORT} root@$(hostname -I | awk '{print $1}')${NC}"
    echo ""
    warn "Port 22 is now blocked. Do not close this session until you verify the new port works."
    echo ""
}

# ─── Router ───────────────────────────────────────────────────────────────────
case "${1:-}" in
    install) cmd_install "$2" ;;
    harden)  cmd_harden "$2" ;;
    list)    cmd_list ;;
    status)  cmd_status ;;
    *)       usage ;;
esac
