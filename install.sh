#!/bin/bash
# ================================================================
#  n8n Installer · n8n.swmathe.de
#  Ubuntu 24.04.5 LTS · Docker · PostgreSQL 16 · Traefik SSL
#  https://github.com/Horst803/n8n-hetzner-setup
# ================================================================
set -euo pipefail

# Farben
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; NC='\033[0m'

# Konfiguration
N8N_DOMAIN="n8n.swmathe.de"
N8N_DIR="/opt/n8n"
TZ="Europe/Berlin"

echo -e "${BLU}"
echo "╔══════════════════════════════════════════════╗"
echo "║   n8n Installer · Ubuntu 24.04 LTS          ║"
echo "║   Domain: n8n.swmathe.de                    ║"
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
read -p "📧  E-Mail für Let's Encrypt SSL: " LE_EMAIL
read -p "👤  n8n Admin-Benutzername:        " N8N_USER
read -s -p "🔒  n8n Admin-Passwort:            " N8N_PASS
echo ""
echo ""

# Zufällige Secrets
PG_PASS=$(openssl rand -hex 24)
ENC_KEY=$(openssl rand -hex 24)

# ── 1/6 System aktualisieren ─────────────────────────────────
echo -e "${YLW}[1/6] System aktualisieren...${NC}"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl gnupg openssl ufw
echo -e "${GRN}✓ System aktuell${NC}"

# ── 2/6 Docker installieren ──────────────────────────────────
echo -e "${YLW}[2/6] Docker installieren...${NC}"
if ! command -v docker &>/dev/null; then
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

# ── 3/6 Verzeichnisse anlegen ────────────────────────────────
echo -e "${YLW}[3/6] Verzeichnisse anlegen...${NC}"
mkdir -p ${N8N_DIR}/{data,postgres,traefik/certs}
touch ${N8N_DIR}/traefik/certs/acme.json
chmod 600 ${N8N_DIR}/traefik/certs/acme.json
echo -e "${GRN}✓ Verzeichnisse erstellt unter ${N8N_DIR}${NC}"

# ── 4/6 Konfiguration schreiben ──────────────────────────────
echo -e "${YLW}[4/6] Konfiguration schreiben...${NC}"

# .env
cat > ${N8N_DIR}/.env << EOF
N8N_DOMAIN=${N8N_DOMAIN}
LE_EMAIL=${LE_EMAIL}
POSTGRES_DB=n8n
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${PG_PASS}
N8N_ADMIN_EMAIL=${N8N_USER}
N8N_ADMIN_PASSWORD=${N8N_PASS}
N8N_ENCRYPTION_KEY=${ENC_KEY}
TZ=${TZ}
EOF
chmod 600 ${N8N_DIR}/.env

# traefik.yml
cat > ${N8N_DIR}/traefik/traefik.yml << TRAEFIK
api:
  dashboard: false
log:
  level: ERROR
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"
certificatesResolvers:
  letsencrypt:
    acme:
      email: ${LE_EMAIL}
      storage: /certs/acme.json
      httpChallenge:
        entryPoint: web
providers:
  docker:
    exposedByDefault: false
    network: n8n_net
TRAEFIK

# docker-compose.yml
cat > ${N8N_DIR}/docker-compose.yml << 'COMPOSE'
services:

  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/traefik.yml:ro
      - ./traefik/certs:/certs
    networks: [n8n_net]

  postgres:
    image: postgres:16-alpine
    container_name: n8n_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    env_file: .env
    volumes:
      - ./postgres:/var/lib/postgresql/data
    networks: [n8n_net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
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
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_HOST: ${N8N_DOMAIN}
      N8N_PROTOCOL: https
      N8N_PORT: 5678
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      GENERIC_TIMEZONE: ${TZ}
      TZ: ${TZ}
    env_file: .env
    volumes:
      - ./data:/home/node/.n8n
    networks: [n8n_net]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_DOMAIN}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls=true"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"

networks:
  n8n_net:
    driver: bridge
COMPOSE

echo -e "${GRN}✓ Konfiguration geschrieben${NC}"

# ── 5/6 Firewall ─────────────────────────────────────────────
echo -e "${YLW}[5/6] Firewall (ufw) einrichten...${NC}"
ufw allow 22/tcp  comment 'SSH'            > /dev/null
ufw allow 80/tcp  comment 'HTTP Redirect'  > /dev/null
ufw allow 443/tcp comment 'HTTPS n8n'      > /dev/null
ufw --force enable                         > /dev/null
echo -e "${GRN}✓ Firewall aktiv (Ports: 22, 80, 443)${NC}"

# ── 6/6 Container starten ────────────────────────────────────
echo -e "${YLW}[6/6] n8n starten...${NC}"
cd ${N8N_DIR}
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
echo "║                                                  ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  SSL-Zertifikat: automatisch (~1-2 Min.)         ║"
echo "║  Beim ersten Aufruf: Admin-Account anlegen       ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

docker compose ps
