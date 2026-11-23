#!/bin/bash
# ================================================================
#  n8n Installer · n8n.swmathe.de
#  Ubuntu 24.04.5 LTS · Docker · PostgreSQL 16 · Caddy SSL
#  Caddy läuft bereits auf dem Server – wird als Reverse Proxy genutzt
#  https://github.com/Horst803/n8n-hetzner-setup
# ================================================================
set -euo pipefail

# Farben
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; NC='\033[0m'

# Konfiguration
N8N_DOMAIN="n8n.swmathe.de"
N8N_DIR="/opt/n8n"
N8N_PORT="5678"
TZ="Europe/Berlin"
CADDY_CONFIG="/etc/caddy/Caddyfile"

echo -e "${BLU}"
echo "╔══════════════════════════════════════════════╗"
echo "║   n8n Installer · Ubuntu 24.04 LTS          ║"
echo "║   Domain: n8n.swmathe.de  (via Caddy)       ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# Root-Check
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Fehler: Bitte mit sudo ausführen: sudo bash install.sh${NC}"
  exit 1
fi

# Eingaben abfragen
echo "Bitte folgende Angaben machen:"
echo ""
read -p "👤  n8n Admin-Benutzername:  " N8N_USER
read -s -p "🔒  n8n Admin-Passwort:      " N8N_PASS
echo ""
echo ""

# Zufällige Secrets
PG_PASS=$(openssl rand -hex 24)
ENC_KEY=$(openssl rand -hex 24)

# ── 1/5 System-Pakete sicherstellen ──────────────────────────
echo -e "${YLW}[1/5] Abhängigkeiten prüfen...${NC}"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg openssl ufw caddy
echo -e "${GRN}✓ Alles vorhanden${NC}"

# ── 2/5 Docker prüfen ────────────────────────────────────────
echo -e "${YLW}[2/5] Docker prüfen...${NC}"
if ! command -v docker &>/dev/null; then
  echo -e "${YLW}Docker nicht gefunden – wird installiert...${NC}"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  usermod -aG docker swadmin 2>/dev/null || true
  echo -e "${GRN}✓ Docker installiert${NC}"
else
  echo -e "${GRN}✓ Docker bereits vorhanden ($(docker --version | cut -d' ' -f3))${NC}"
fi

# ── 3/5 Verzeichnisse & Konfiguration ────────────────────────
echo -e "${YLW}[3/5] Verzeichnisse und Konfiguration anlegen...${NC}"
mkdir -p ${N8N_DIR}/{data,postgres}

# .env – alle Secrets
cat > ${N8N_DIR}/.env << EOF
POSTGRES_DB=n8n
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${PG_PASS}
N8N_ADMIN_EMAIL=${N8N_USER}
N8N_ADMIN_PASSWORD=${N8N_PASS}
N8N_ENCRYPTION_KEY=${ENC_KEY}
TZ=${TZ}
EOF
chmod 600 ${N8N_DIR}/.env

# docker-compose.yml – KEIN Traefik, kein Port 80/443
# n8n hört nur auf 127.0.0.1:5678 → Caddy leitet weiter
cat > ${N8N_DIR}/docker-compose.yml << EOF
services:

  postgres:
    image: postgres:16-alpine
    container_name: n8n_postgres
    restart: unless-stopped
    env_file: .env
    environment:
      POSTGRES_DB: \${POSTGRES_DB}
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - ./postgres:/var/lib/postgresql/data
    networks: [n8n_net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 20s

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:${N8N_PORT}:5678"
    env_file: .env
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: \${POSTGRES_DB}
      DB_POSTGRESDB_USER: \${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: \${POSTGRES_PASSWORD}
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PROTOCOL: https
      N8N_PORT: 5678
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      N8N_ENCRYPTION_KEY: \${N8N_ENCRYPTION_KEY}
      GENERIC_TIMEZONE: \${TZ}
      TZ: \${TZ}
    volumes:
      - ./data:/home/node/.n8n
    networks: [n8n_net]

networks:
  n8n_net:
    driver: bridge
EOF

echo -e "${GRN}✓ Konfiguration geschrieben${NC}"

# ── 4/5 Caddy Reverse Proxy einrichten ───────────────────────
echo -e "${YLW}[4/5] Caddy Reverse Proxy konfigurieren...${NC}"

# Prüfen ob der Block schon existiert
if grep -q "${N8N_DOMAIN}" "${CADDY_CONFIG}" 2>/dev/null; then
  echo -e "${GRN}✓ Caddy-Eintrag für ${N8N_DOMAIN} bereits vorhanden – übersprungen${NC}"
else
  # Sicherheitskopie der aktuellen Caddyfile
  cp "${CADDY_CONFIG}" "${CADDY_CONFIG}.backup-$(date +%Y%m%d%H%M%S)"

  # n8n-Block ans Ende der Caddyfile anhängen
  cat >> "${CADDY_CONFIG}" << EOF

# ── n8n · automatisch hinzugefügt ──────────────────
${N8N_DOMAIN} {
    reverse_proxy 127.0.0.1:${N8N_PORT}
}
EOF

  echo -e "${GRN}✓ Caddy-Eintrag hinzugefügt (Backup: ${CADDY_CONFIG}.backup-*)${NC}"
fi

# Caddy-Konfiguration testen und neu laden (KEIN Neustart nötig!)
caddy fmt --overwrite "${CADDY_CONFIG}" 2>/dev/null || true
caddy validate --config "${CADDY_CONFIG}" 2>/dev/null && \
  systemctl reload caddy && \
  echo -e "${GRN}✓ Caddy neu geladen – laufende Dienste nicht unterbrochen${NC}" || \
  echo -e "${RED}⚠ Caddy-Validierung fehlgeschlagen – manuelle Prüfung nötig${NC}"

# ── 5/5 Container starten ────────────────────────────────────
echo -e "${YLW}[5/5] n8n starten...${NC}"
cd ${N8N_DIR}

# Alte fehlerhafte Container aufräumen falls vorhanden
docker compose down 2>/dev/null || true

docker compose up -d

echo -e "${YLW}Warte auf n8n (max. 2 Min.)...${NC}"
READY=false
for i in {1..24}; do
  sleep 5
  if docker compose ps | grep -q "n8n.*running"; then
    READY=true
    break
  fi
  echo -n "."
done
echo ""

if [ "$READY" = true ]; then
  echo -e "${GRN}✓ n8n läuft!${NC}"
else
  echo -e "${RED}⚠ Timeout – prüfe mit: cd /opt/n8n && docker compose logs n8n${NC}"
fi

# ── Ergebnis ─────────────────────────────────────────────────
echo -e "\n${GRN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║          ✅  n8n Setup abgeschlossen!            ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║                                                  ║"
echo "║  🌐  https://n8n.swmathe.de                     ║"
echo "║  📁  Daten:   /opt/n8n/data                     ║"
echo "║  🗄   DB:      /opt/n8n/postgres                 ║"
echo "║  🔑  Secrets: /opt/n8n/.env                     ║"
echo "║  🔀  Proxy:   Caddy (kein Traefik)              ║"
echo "║                                                  ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  SSL: automatisch via Caddy + Let's Encrypt      ║"
echo "║  Caddy läuft weiter für alle anderen Dienste     ║"
echo "║  Beim ersten Aufruf: Admin-Account anlegen       ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

docker compose ps
