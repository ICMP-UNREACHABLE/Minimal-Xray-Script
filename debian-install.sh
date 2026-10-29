#!/usr/bin/env bash
# Debian Xray REALITY / Hysteria 2 installer
# Requires systemd.

set -Eeuo pipefail
umask 077

XRAY_BIN="/usr/local/bin/xray"
XRAY_CLI_LINK="/usr/local/sbin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_ASSET_DIR="/usr/local/share/xray"
XRAY_LOG_DIR="/var/log/xray"

REALITY_TARGET="www.amazon.com:443"
REALITY_SNI="www.amazon.com"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
    printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2
}

die() {
    printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Please run as root."
    command -v systemctl >/dev/null 2>&1 ||
        die "systemd is required."
}

install_deps() {
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y \
        ca-certificates \
        curl \
        unzip \
        openssl \
        coreutils \
        grep \
        sed \
        gawk \
        util-linux \
        python3
}

getIP() {
    local ip=""

    ip=$(curl -4 -fsS \
        --connect-timeout 5 --max-time 10 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
        awk -F= '$1=="ip"{print $2;exit}' || true)

    if [[ -z "$ip" ]]; then
        ip=$(curl -6 -fsS \
            --connect-timeout 5 --max-time 10 \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
            awk -F= '$1=="ip"{print $2;exit}' || true)
    fi

    printf '%s\n' "${ip:-SERVER_IP}"
}

formatUriHost() {
    local host="$1"

    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

getShortId() {
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

selectRealityPort() {
    local input=""

    if [[ -n "${XRAY_PORT:-}" ]]; then
        getPort="$XRAY_PORT"
    else
        read -r -t 15 -p "REALITY listen port [443]: " input || true
        getPort="${input:-443}"
    fi

    [[ "$getPort" =~ ^[0-9]+$ ]] ||
        die "Invalid port: $getPort"

    (( 10#$getPort >= 1 && 10#$getPort <= 65535 )) ||
        die "Port must be between 1 and 65535."

    getPort=$((10#$getPort))

    if (( getPort != 443 )); then
        warn "REALITY on a non-443 port may be less compatible."
    fi
}

generateRealityCredentials() {
    local output

    v2uuid=$("$XRAY_BIN" uuid | tr -d '\r\n') ||
        die "Failed to generate UUID."

    output=$("$XRAY_BIN" x25519) ||
        die "Failed to generate REALITY keys."

    rePrivateKey=$(printf '%s\n' "$output" |
        awk -F':[[:space:]]*' \
            '$1 ~ /^(PrivateKey|Private key)$/ {print $2;exit}' |
        tr -d '\r')

    rePublicKey=$(printf '%s\n' "$output" |
        awk -F':[[:space:]]*' \
            '$1 ~ /^(Password|PublicKey|Public key)( \(PublicKey\))?$/ {
                print $2;exit
            }' |
        tr -d '\r')

    shortId1=$(getShortId)
    shortId2=$(getShortId)

    [[ -n "$v2uuid" ]] || die "Empty UUID."
    [[ -n "$rePrivateKey" ]] || die "Could not parse private key."
    [[ -n "$rePublicKey" ]] || die "Could not parse public key."
    [[ "$shortId1" =~ ^[0-9a-f]{16}$ ]] ||
        die "Invalid short ID."
    [[ "$shortId2" =~ ^[0-9a-f]{16}$ ]] ||
        die "Invalid short ID."
}

validateXrayConfig() {
    local file="$1"
    local output

    if ! output=$(XRAY_LOCATION_ASSET="$XRAY_ASSET_DIR" \
        "$XRAY_BIN" run -test -format json -c "$file" 2>&1); then
        printf '%s\n' "$output" >&2
        return 1
    fi

    [[ -z "$output" ]] || printf '%s\n' "$output"
}

installXrayConfig() {
    local tmpdir tmpconfig backup=""

    tmpdir=$(mktemp -d) || die "Cannot create temporary directory."
    tmpconfig="$tmpdir/config.json"

    cat >"$tmpconfig" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${getPort},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${v2uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${serverName}:443",
          "xver": 0,
          "serverNames": [
            "${sniName}"
          ],
          "privateKey": "${rePrivateKey}",
          "maxTimeDiff": 0,
          "shortIds": [
            "${shortId1}",
            "${shortId2}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

    if ! validateXrayConfig "$tmpconfig"; then
        rm -rf "$tmpdir"
        die "Xray configuration validation failed."
    fi

    mkdir -p "$XRAY_CONFIG_DIR"

    if [[ -f "$XRAY_CONFIG" ]]; then
        backup="${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$XRAY_CONFIG" "$backup"
        log "Backup: $backup"
    fi

    install -m 0600 "$tmpconfig" "$XRAY_CONFIG"
    rm -rf "$tmpdir"

    systemctl enable xray
    systemctl restart xray ||
        die "Failed to start Xray. Check journalctl -u xray."

    systemctl is-active --quiet xray ||
        die "Xray is not running."
}

configReality() {
    generateRealityCredentials
    selectRealityPort

    serverName="${REALITY_TARGET%:*}"
    sniName="$REALITY_SNI"

    installXrayConfig
}

configRealityRegion() {
    local input index

    local -a destNames=(
        "www.t-mobile.com"
        "www.arm.com"
        "www.tsukuba.ac.jp"
        "www.hongkongdisneyland.com"
        "www.china-airlines.com"
        "sigtelinc.com"
        "www.bouyguestelecom.fr"
        "www.mercedes-benz.de"
        "www.incredibleindia.gov.in"
        "www.amazon.com"
    )

    local -a sniNames=(
        "business.t-mobile.com"
        "learn.arm.com"
        "www.tsukuba.ac.jp"
        "entitlement.hongkongdisneyland.com"
        "book.china-airlines.com"
        "www.sigtelinc.com"
        "www.bouygtel.fr"
        "pro.mercedes-benz.com"
        "www.incredibleindia.org"
        "corporate.amazon.com"
    )

    echo "Please select a region:"
    echo "1. US"
    echo "2. UK"
    echo "3. JP"
    echo "4. HK"
    echo "5. TW"
    echo "6. SG"
    echo "7. FR"
    echo "8. DE"
    echo "9. IN"
    echo "10. Others"

    read -r -p "Choice [1-10]: " input

    [[ "$input" =~ ^([1-9]|10)$ ]] ||
        die "Invalid region selection."

    index=$((input - 1))
    serverName="${destNames[$index]}"
    sniName="${sniNames[$index]}"

    generateRealityCredentials
    selectRealityPort
    installXrayConfig
}

detectXrayAsset() {
    case "$(uname -m)" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l|armv7) echo "arm32-v7a" ;;
        armv6l|armv6) echo "arm32-v6" ;;
        i386|i486|i586|i686) echo "32" ;;
        riscv64) echo "riscv64" ;;
        *) die "Unsupported architecture: $(uname -m)" ;;
    esac
}

getLatestXrayVersion() {
    local json version url

    if [[ -n "${XRAY_VERSION:-}" ]]; then
        printf 'v%s\n' "${XRAY_VERSION#v}"
        return
    fi

    json=$(curl -fsSL --retry 3 \
        --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest) ||
        die "Failed to query Xray release."

    version=$(printf '%s\n' "$json" |
        python3 -c '
import json,sys
print(json.load(sys.stdin).get("tag_name",""))
' 2>/dev/null) || true

    if [[ -z "$version" ]]; then
        url=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            --connect-timeout 10 --max-time 30 \
            https://github.com/XTLS/Xray-core/releases/latest) ||
            die "Unable to determine Xray version."

        version="${url##*/}"
    fi

    [[ "$version" == v* ]] ||
        die "Invalid Xray version: $version"

    printf '%s\n' "$version"
}

installXray() {
    local version asset tmpdir zip digest url
    local expected actual file

    install_deps

    version=$(getLatestXrayVersion)
    asset=$(detectXrayAsset)

    tmpdir=$(mktemp -d) ||
        die "Cannot create temporary directory."

    zip="$tmpdir/xray.zip"
    digest="$tmpdir/xray.zip.dgst"

    url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${asset}.zip"

    log "Downloading Xray $version for $(uname -m)..."

    if ! curl -fL --retry 3 \
        --connect-timeout 10 --max-time 180 \
        -o "$zip" "$url"; then
        rm -rf "$tmpdir"
        die "Failed to download Xray."
    fi

    # Verify SHA-256 when a usable digest is available.
    if curl -fsSL --retry 2 \
        --connect-timeout 10 --max-time 30 \
        -o "$digest" "${url}.dgst"; then

        expected=$(awk '
            /SHA256/ {
                for (i=1;i<=NF;i++)
                    if ($i ~ /^[[:xdigit:]]{64}$/) {
                        print $i
                        exit
                    }
            }
        ' "$digest")

        if [[ -n "$expected" ]]; then
            actual=$(sha256sum "$zip" | awk '{print $1}')

            if [[ "${actual,,}" != "${expected,,}" ]]; then
                rm -rf "$tmpdir"
                die "Xray SHA-256 verification failed."
            fi

            log "SHA-256 verified."
        else
            warn "Digest format not recognized; checksum not verified."
        fi
    else
        warn "Digest unavailable; checksum not verified."
    fi

    for file in xray geoip.dat geosite.dat; do
        if ! unzip -p "$zip" "$file" >"$tmpdir/$file"; then
            rm -rf "$tmpdir"
            die "Failed to extract $file."
        fi

        if [[ ! -s "$tmpdir/$file" ]]; then
            rm -rf "$tmpdir"
            die "Extracted file is empty: $file"
        fi
    done

    chmod 0755 "$tmpdir/xray"

    if ! "$tmpdir/xray" version >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        die "Downloaded Xray binary cannot run."
    fi

    mkdir -p \
        "$XRAY_CONFIG_DIR" \
        "$XRAY_ASSET_DIR" \
        "$XRAY_LOG_DIR" \
        "$(dirname "$XRAY_CLI_LINK")"

    # Stop the service before replacing the binary.
    systemctl stop xray 2>/dev/null || true

    install -m 0755 "$tmpdir/xray" "$XRAY_BIN"
    install -m 0644 "$tmpdir/geoip.dat" \
        "$XRAY_ASSET_DIR/geoip.dat"
    install -m 0644 "$tmpdir/geosite.dat" \
        "$XRAY_ASSET_DIR/geosite.dat"

    ln -sfn "$XRAY_BIN" "$XRAY_CLI_LINK"

    rm -rf "$tmpdir"

    cat >/etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 /etc/systemd/system/xray.service
    systemctl daemon-reload

    log "Installed: $("$XRAY_BIN" version | head -n 1)"

    echo
    echo "Please select a configuration method:"
    echo "1) Auto Config (Amazon target)"
    echo "2) Manual/Regional Config"
    echo "3) Exit"

    local choice

    while true; do
        read -r -p "Enter your choice (1-3): " choice

        case "$choice" in
            1)
                configReality
                break
                ;;
            2)
                configRealityRegion
                break
                ;;
            3)
                echo "Exiting."
                return 0
                ;;
            *)
                echo "Invalid input."
                ;;
        esac
    done

    client_re
}

client_re() {
    local serverIP uriHost uri resultFile

    serverIP=$(getIP)
    uriHost=$(formatUriHost "$serverIP")

    uri="vless://${v2uuid}@${uriHost}:${getPort}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sniName}&fp=chrome&pbk=${rePublicKey}&sid=${shortId1}&type=tcp#xrayReality"

    resultFile="/root/xray-reality.txt"

    cat >"$resultFile" <<EOF
Address: ${serverIP}
Port: ${getPort}
UUID: ${v2uuid}
Flow: xtls-rprx-vision
Transport: tcp
Security: reality
Target: ${serverName}:443
SNI: ${sniName}
Public key: ${rePublicKey}
Short ID: ${shortId1}

${uri}
EOF

    chmod 0600 "$resultFile"

    echo
    echo "Xray REALITY installation completed."
    echo "===================================="
    echo "Address:    ${serverIP}"
    echo "Port:       ${getPort}"
    echo "UUID:       ${v2uuid}"
    echo "Flow:       xtls-rprx-vision"
    echo "Public key: ${rePublicKey}"
    echo "Target:     ${serverName}:443"
    echo "SNI:        ${sniName}"
    echo "Short ID:   ${shortId1}"
    echo "===================================="
    echo "$uri"
    echo
    echo "Saved to: $resultFile"
    echo "Service: systemctl status xray"
}

installHy2() {
    local version arch url tmpfile
    local password port serverIP

    install_deps

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7) arch="armv7" ;;
        *)
            die "Unsupported Hysteria architecture: $(uname -m)"
            ;;
    esac

    version=$(curl -fsSL --retry 3 \
        --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/apernet/hysteria/releases/latest |
        python3 -c '
import json,sys
print(json.load(sys.stdin).get("tag_name",""))
') || die "Failed to query Hysteria release."

    [[ -n "$version" ]] ||
        die "Unable to determine Hysteria version."

    password=$(openssl rand -hex 24)
    port=$(shuf -i 10000-65000 -n 1)

    tmpfile=$(mktemp) ||
        die "Cannot create temporary file."

    url="https://github.com/apernet/hysteria/releases/download/${version}/hysteria-linux-${arch}"

    log "Downloading Hysteria $version..."

    if ! curl -fL --retry 3 \
        --connect-timeout 10 --max-time 180 \
        -o "$tmpfile" "$url"; then
        rm -f "$tmpfile"
        die "Failed to download Hysteria."
    fi

    chmod 0755 "$tmpfile"

    if ! "$tmpfile" version >/dev/null 2>&1; then
        rm -f "$tmpfile"
        die "Downloaded Hysteria binary cannot run."
    fi

    systemctl stop hysteria 2>/dev/null || true

    install -m 0755 "$tmpfile" /usr/local/bin/hysteria
    rm -f "$tmpfile"

    mkdir -p /etc/hysteria /var/log

    openssl req -x509 -nodes -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/server.key \
        -out /etc/hysteria/server.crt \
        -subj "/CN=bing.com" -days 3650

    chmod 0600 /etc/hysteria/server.key
    chmod 0644 /etc/hysteria/server.crt

    cat >/etc/hysteria/config.yaml <<EOF
listen: :${port}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 1048576
  maxStreamReceiveWindow: 4194304
  initConnReceiveWindow: 4194304
  maxConnReceiveWindow: 8388608

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF

    chmod 0600 /etc/hysteria/config.yaml

    cat >/etc/systemd/system/hysteria.service <<'EOF'
[Unit]
Description=Hysteria 2 Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 /etc/systemd/system/hysteria.service
    systemctl daemon-reload
    systemctl enable hysteria

    systemctl restart hysteria ||
        die "Hysteria failed to start. Check journalctl -u hysteria."

    systemctl is-active --quiet hysteria ||
        die "Hysteria is not running."

    serverIP=$(getIP)

    echo
    echo "===================================="
    echo "Hysteria 2 installation completed."
    echo "Address: ${serverIP}"
    echo "Port: ${port}"
    echo "Password: ${password}"
    echo "TLS: self-signed certificate"
    echo
    echo "Connection string:"
    echo "hysteria2://${password}@${serverIP}:${port}/?insecure=1&sni=bing.com#Hysteria2"
    echo
    echo "Config: /etc/hysteria/config.yaml"
    echo "Service: systemctl status hysteria"
    echo "===================================="
    echo
    warn "Ensure inbound UDP port ${port} is allowed by your firewall and hosting provider."
}

menu() {
    local option

    while true; do
        echo
        echo "Debian Proxy Installer"
        echo "0. Exit"
        echo "1. Install Xray and configure REALITY"
        echo "2. Install Hysteria 2"

        read -r -p "Select: " option

        case "$option" in
            0) exit 0 ;;
            1) installXray; return ;;
            2) installHy2; return ;;
            *) echo "Invalid option." ;;
        esac
    done
}

require_root
menu
