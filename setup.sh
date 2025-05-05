#!/bin/bash
set -e

# Farben
green='\033[0;32m'
bold='\033[1m'
reset='\033[0m'

# Helper
ask() {
  read -rp "$1 " REPLY
  echo "$REPLY"
}

# install wireguard und stunnel
if ! command -v wg &> /dev/null; then
  echo -e "${green}Installiere WireGuard...${reset}"
  apt update && apt install -y wireguard
else
  echo -e "${green}WireGuard ist bereits installiert.${reset}"
fi
if ! command -v stunnel &> /dev/null; then
  echo -e "${green}Installiere Stunnel...${reset}"
  apt install -y stunnel
else
  echo -e "${green}Stunnel ist bereits installiert.${reset}"
fi
if ! command -v openssl &> /dev/null; then
  echo -e "${green}Installiere OpenSSL...${reset}"
  apt install -y openssl
else
  echo -e "${green}OpenSSL ist bereits installiert.${reset}"
fi



echo -e "${bold}WireGuard über Stunnel Setup${reset}"
ROLE=$(ask "🔧 Rolle wählen [server/client]:")

if [[ "$ROLE" != "server" && "$ROLE" != "client" ]]; then
  echo "❌ Ungültige Rolle."
  exit 1
fi

USER_NAME=$(ask "👤 Benutzername für stunnel-Dienst (Client=lokaler User):")

# Allgemein
WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
SSL_DIR="/etc/stunnel"

mkdir -p "$WG_DIR"
mkdir -p "$SSL_DIR"
umask 077

##############################
### SERVER SETUP
##############################
if [[ "$ROLE" == "server" ]]; then
  echo -e "${bold}🚧 Server-Konfiguration wird erstellt...${reset}"
  SERVER_PRIV=$(wg genkey)
  SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)
  echo "$SERVER_PRIV" > "$WG_DIR/server_private.key"
  echo "$SERVER_PUB" > "$WG_DIR/server_public.key"

  WG_IP="10.10.0.1/24"
  WG_PORT=51820

  # WireGuard Config
  cat > "$WG_DIR/$WG_IFACE.conf" <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = $WG_IP
ListenPort = $WG_PORT
EOF

  # Self-signed TLS-Zertifikat
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SSL_DIR/wg-key.pem" -out "$SSL_DIR/wg-cert.pem" -days 365 -subj "/CN=wg-server"

  # Stunnel Config
  cat > "$SSL_DIR/wg443.conf" <<EOF
[wgtunnel]
accept = 443
connect = 127.0.0.1:$WG_PORT
cert = $SSL_DIR/wg-cert.pem
key = $SSL_DIR/wg-cert.pem
EOF

  # Systemd Unit
  cat > /etc/systemd/system/stunnel@wg443.service <<EOF
[Unit]
Description=Stunnel for %i
After=network.target

[Service]
ExecStart=/usr/bin/stunnel /etc/stunnel/%i.conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  # Serverinfo Skript
  cat > /usr/local/bin/wg-show-client-info <<EOF
#!/bin/bash
echo "📡 WireGuard Server Info:"
echo "Public Key:"
cat $WG_DIR/server_public.key
echo ""
echo "Assigned Server IP:"
grep Address $WG_DIR/$WG_IFACE.conf | cut -d'=' -f2 | tr -d ' '
EOF

  chmod +x /usr/local/bin/wg-show-client-info

  systemctl enable stunnel@wg443
  systemctl enable wg-quick@$WG_IFACE

  echo -e "${green}✅ Server-Setup abgeschlossen.${reset}"
  echo "➡️   Starte mit: sudo systemctl start stunnel@wg443 && sudo systemctl start wg-quick@$WG_IFACE"
  echo "🔑   Public Key für Client:"
  cat "$WG_DIR/server_public.key"

##############################
### CLIENT SETUP
##############################
elif [[ "$ROLE" == "client" ]]; then
  SERVER_DOMAIN=$(ask "🌍 Server IP oder Domain:")
  SERVER_PUB=$(ask "🔑 Public Key vom Server (bitte einfügen):")

  CLIENT_PRIV=$(wg genkey)
  CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)
  echo "$CLIENT_PRIV" > "$WG_DIR/client_private.key"
  echo "$CLIENT_PUB" > "$WG_DIR/client_public.key"

  WG_IP="10.10.0.2/24"
  TUNNEL_PORT=12345

  # WireGuard Config
  cat > "$WG_DIR/$WG_IFACE.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $WG_IP

[Peer]
PublicKey = $SERVER_PUB
Endpoint = 127.0.0.1:$TUNNEL_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  mkdir -p "/home/$USER_NAME/stunnel"

  # Stunnel Config
  cat > "/home/$USER_NAME/stunnel/wg-client.conf" <<EOF
[wgtunnel]
client = yes
accept = 127.0.0.1:$TUNNEL_PORT
connect = $SERVER_DOMAIN:443
verify = 0
EOF

  # Systemd Unit
  cat > /etc/systemd/system/stunnel@wg-client.service <<EOF
[Unit]
Description=Stunnel for %i
After=network.target

[Service]
ExecStart=/usr/bin/stunnel /home/$USER_NAME/stunnel/%i.conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
User=$USER_NAME

[Install]
WantedBy=multi-user.target
EOF

  chown -R "$USER_NAME":"$USER_NAME" "/home/$USER_NAME/stunnel"

  systemctl enable stunnel@wg-client
  systemctl enable wg-quick@$WG_IFACE

  echo -e "${green}✅ Client-Setup abgeschlossen.${reset}"
  echo "➡️   Starte mit: sudo systemctl start stunnel@wg-client && sudo systemctl start wg-quick@$WG_IFACE"
  echo "📤 Sende diesen Public Key an den Server:"
  echo "$CLIENT_PUB"
fi
