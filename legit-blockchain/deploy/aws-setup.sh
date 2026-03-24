#!/usr/bin/env bash
# deploy/aws-setup.sh
# One-shot bootstrap for Amazon Linux 2023 (t3.small+)
# Usage: sudo bash aws-setup.sh
# Set LEGIT_SECRET_ARN env var before running to pull secrets from AWS Secrets Manager

set -euo pipefail
IFS=$'\n\t'

APP_DIR="/opt/legit/blockchain"
LOG_DIR="/var/log/legit"
ENV_FILE="/etc/legit/blockchain.env"
IMAGE_NAME="legit-blockchain"
IMAGE_TAG="latest"
CONTAINER_NAME="legit-blockchain"
HOST_PORT="3001"
CONTAINER_PORT="3001"
SECRET_ARN="${LEGIT_SECRET_ARN:-}"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
info()  { echo -e "${G}[INFO]${N}  $*"; }
warn()  { echo -e "${Y}[WARN]${N}  $*"; }
die()   { echo -e "${R}[FAIL]${N}  $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash aws-setup.sh"

info "Updating system packages…"
dnf update -y -q

info "Installing Docker, git, curl, jq, unzip…"
dnf install -y -q docker git curl jq unzip

info "Starting Docker…"
systemctl enable --now docker
usermod -aG docker ec2-user 2>/dev/null || true

if ! command -v aws &>/dev/null; then
  info "Installing AWS CLI v2…"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awsv2.zip
  unzip -q /tmp/awsv2.zip -d /tmp/awsv2
  /tmp/awsv2/aws/install --update -q
  rm -rf /tmp/awsv2.zip /tmp/awsv2
fi

info "Creating directories…"
mkdir -p "${APP_DIR}" "${LOG_DIR}" /etc/legit
chmod 755 "${APP_DIR}" "${LOG_DIR}"
id legit &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin legit
chown legit:legit "${LOG_DIR}"

if [[ -n "${SECRET_ARN}" ]]; then
  info "Fetching secrets from Secrets Manager: ${SECRET_ARN}"
  aws secretsmanager get-secret-value \
      --secret-id "${SECRET_ARN}" \
      --query SecretString \
      --output text \
    | jq -r 'to_entries[] | "\(.key)=\(.value)"' \
    > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  chown root:root "${ENV_FILE}"
  info "Secrets written to ${ENV_FILE}"
else
  warn "LEGIT_SECRET_ARN not set — skipping Secrets Manager pull."
  [[ -f "${ENV_FILE}" ]] || { touch "${ENV_FILE}"; chmod 600 "${ENV_FILE}"; }
  warn "Fill ${ENV_FILE} manually before starting the container."
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(dirname "${SCRIPT_DIR}")"

info "Copying source to ${APP_DIR}…"
rsync -a --delete \
  --exclude='.env' \
  --exclude='node_modules' \
  --exclude='.git' \
  "${SOURCE_DIR}/" "${APP_DIR}/"

info "Building Docker image ${IMAGE_NAME}:${IMAGE_TAG}…"
docker build --no-cache --pull --tag "${IMAGE_NAME}:${IMAGE_TAG}" "${APP_DIR}"

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  info "Stopping existing container (65s graceful drain)…"
  docker stop --time 65 "${CONTAINER_NAME}" 2>/dev/null || true
  docker rm   "${CONTAINER_NAME}"           2>/dev/null || true
fi

info "Starting ${CONTAINER_NAME}…"
docker run \
  --name              "${CONTAINER_NAME}" \
  --detach \
  --restart           unless-stopped \
  --env-file          "${ENV_FILE}" \
  --publish           "127.0.0.1:${HOST_PORT}:${CONTAINER_PORT}" \
  --mount             type=bind,source="${LOG_DIR}",target="/var/log/legit" \
  --memory            512m \
  --memory-swap       512m \
  --cpus              1.0 \
  --security-opt      no-new-privileges:true \
  --cap-drop          ALL \
  "${IMAGE_NAME}:${IMAGE_TAG}"

info "Waiting for health check (max 60s)…"
TRIES=0
until curl -sf "http://127.0.0.1:${HOST_PORT}/health" >/dev/null 2>&1; do
  TRIES=$((TRIES + 1))
  [[ $TRIES -ge 12 ]] && die "Container not healthy after 60s. Run: docker logs ${CONTAINER_NAME}"
  printf '.'; sleep 5
done
echo ""; info "Container is healthy."

info "Installing systemd unit…"
cat > /etc/systemd/system/legit-blockchain.service << UNIT
[Unit]
Description=LEGIT Blockchain Microservice (Docker)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStartPre=/usr/bin/docker start ${CONTAINER_NAME} || true
ExecStart=/usr/bin/docker start -a ${CONTAINER_NAME}
ExecStop=/usr/bin/docker stop -t 65 ${CONTAINER_NAME}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=legit-blockchain

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable legit-blockchain
info "Systemd unit enabled."

info "Configuring logrotate…"
cat > /etc/logrotate.d/legit-blockchain << 'LOGROTATE'
/var/log/legit/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 legit legit
    sharedscripts
    postrotate
        /usr/bin/docker kill --signal=USR1 legit-blockchain 2>/dev/null || true
    endscript
}
LOGROTATE

docker image prune -f --filter "until=24h" >/dev/null 2>&1 || true

echo ""
echo -e "${G}┌────────────────────────────────────────────────────┐${N}"
echo -e "${G}│  LEGIT Blockchain Microservice — Deployed ✓         │${N}"
echo -e "${G}├────────────────────────────────────────────────────┤${N}"
echo -e "${G}│  Health:  http://127.0.0.1:${HOST_PORT}/health          │${N}"
echo -e "${G}│  Metrics: http://127.0.0.1:${HOST_PORT}/metrics         │${N}"
echo -e "${G}│  Logs:    docker logs -f ${CONTAINER_NAME}    │${N}"
echo -e "${G}│  Env:     ${ENV_FILE}           │${N}"
echo -e "${G}└────────────────────────────────────────────────────┘${N}"
