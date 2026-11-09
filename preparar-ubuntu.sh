#!/usr/bin/env bash
set -Eeuo pipefail

# Configuracao inicial de Ubuntu: atualizacoes automaticas, utilizador sudo,
# expansao LVM, QEMU Guest Agent, Docker, Docker Compose e journald.

SUDO_USER_TO_CREATE="knologys"
LV_PATH="/dev/ubuntu-vg/ubuntu-lv"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mAVISO: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

trap 'die "Falha na linha $LINENO. Consulte as mensagens anteriores."' ERR

if [[ ${EUID} -eq 0 ]]; then
  die "Execute este script como utilizador normal, sem 'sudo'. O script pedira a password sudo no inicio."
fi

command -v sudo >/dev/null 2>&1 || die "O comando sudo nao esta instalado."

log "A validar privilegios sudo"
printf 'Introduza a password sudo quando solicitado.\n'
sudo -v

# Mantem a credencial sudo valida enquanto o script estiver em execucao.
(
  while true; do
    sudo -n true
    sleep 50
    kill -0 "$$" 2>/dev/null || exit
  done
) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

log "A atualizar os indices APT e a instalar curl primeiro"
sudo apt-get update
sudo apt-get install -y curl

log "A instalar e configurar unattended-upgrades"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades

sudo cp -a /etc/apt/apt.conf.d/20auto-upgrades \
  "/etc/apt/apt.conf.d/20auto-upgrades.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

UU_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"
sudo cp -a "$UU_FILE" "${UU_FILE}.bak.$(date +%Y%m%d%H%M%S)"
if sudo grep -Eq '^[[:space:]]*//[[:space:]]*Unattended-Upgrade::Automatic-Reboot' "$UU_FILE"; then
  sudo sed -i -E 's|^[[:space:]]*//[[:space:]]*(Unattended-Upgrade::Automatic-Reboot.*)|\1|' "$UU_FILE"
elif ! sudo grep -Eq '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot' "$UU_FILE"; then
  printf '\nUnattended-Upgrade::Automatic-Reboot "true";\n' | sudo tee -a "$UU_FILE" >/dev/null
fi

sudo systemctl enable --now unattended-upgrades

log "A criar ou atualizar o utilizador ${SUDO_USER_TO_CREATE}"
if id "$SUDO_USER_TO_CREATE" >/dev/null 2>&1; then
  warn "O utilizador ${SUDO_USER_TO_CREATE} ja existe; sera apenas adicionado ao grupo sudo."
else
  sudo adduser "$SUDO_USER_TO_CREATE"
fi
sudo usermod -aG sudo "$SUDO_USER_TO_CREATE"

log "A expandir o volume logico e o sistema de ficheiros"
if sudo lvs "$LV_PATH" >/dev/null 2>&1; then
  VG_FREE_BYTES=$(sudo vgs --noheadings --units b --nosuffix -o vg_free "$(sudo lvs --noheadings -o vg_name "$LV_PATH" | xargs)" | tr -d ' ')
  if awk "BEGIN {exit !($VG_FREE_BYTES > 0)}"; then
    sudo lvextend -l +100%FREE "$LV_PATH"
  else
    warn "Nao existe espaco livre no volume group; lvextend foi ignorado."
  fi

  FS_TYPE=$(findmnt -n -o FSTYPE "$LV_PATH" 2>/dev/null || true)
  case "$FS_TYPE" in
    ext2|ext3|ext4) sudo resize2fs "$LV_PATH" ;;
    xfs) sudo xfs_growfs "$(findmnt -n -o TARGET "$LV_PATH")" ;;
    *) warn "Sistema de ficheiros '$FS_TYPE' nao reconhecido. Redimensionamento automatico ignorado." ;;
  esac
else
  warn "Nao foi encontrado o volume logico ${LV_PATH}; expansao LVM ignorada."
fi

log "A instalar o QEMU Guest Agent"
sudo apt-get install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
warn "No Proxmox, ative tambem: VM > Options > QEMU Guest Agent."

log "A instalar o Docker Engine"
TMP_DOCKER_SCRIPT=$(mktemp)
curl -fsSL https://get.docker.com -o "$TMP_DOCKER_SCRIPT"
sudo sh "$TMP_DOCKER_SCRIPT"
rm -f "$TMP_DOCKER_SCRIPT"

log "A configurar a rotacao local dos logs Docker"
sudo install -d -m 0755 /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
  sudo cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
fi
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
sudo systemctl enable --now docker
sudo systemctl restart docker

log "A instalar o comando docker-compose solicitado"
sudo curl -L --fail \
  https://raw.githubusercontent.com/linuxserver/docker-docker-compose/master/run.sh \
  -o /usr/local/bin/docker-compose
sudo chmod 0755 /usr/local/bin/docker-compose

log "A limitar a retencao do systemd-journald a 5 dias"
JOURNALD_FILE="/etc/systemd/journald.conf"
sudo cp -a "$JOURNALD_FILE" "${JOURNALD_FILE}.bak.$(date +%Y%m%d%H%M%S)"
if sudo grep -Eq '^[#[:space:]]*MaxRetentionSec=' "$JOURNALD_FILE"; then
  sudo sed -i -E 's|^[#[:space:]]*MaxRetentionSec=.*|MaxRetentionSec=5day|' "$JOURNALD_FILE"
else
  printf '\nMaxRetentionSec=5day\n' | sudo tee -a "$JOURNALD_FILE" >/dev/null
fi
sudo systemctl restart systemd-journald

log "Validacoes finais"
curl --version | head -n 1
docker --version
if command -v docker-compose >/dev/null 2>&1; then
  docker-compose version || true
fi
systemctl --no-pager --full is-active unattended-upgrades qemu-guest-agent docker || true

if [[ -f docker-compose.yml || -f docker-compose.yaml || -f compose.yml || -f compose.yaml ]]; then
  read -r -p "Foi encontrado um ficheiro Compose. Atualizar os containers agora? [s/N] " REPLY
  if [[ "$REPLY" =~ ^[sS]$ ]]; then
    sudo docker-compose pull
    sudo docker-compose up -d --remove-orphans
    sudo docker image prune -f
  fi
else
  warn "Nao foi encontrado um ficheiro Compose na pasta atual; a atualizacao de containers foi ignorada."
fi

log "Configuracao concluida"
printf '%s\n' \
  "Reinicie a VM se o kernel ou componentes de sistema tiverem sido atualizados." \
  "Confirme no Proxmox que o QEMU Guest Agent esta ativado para esta VM."
