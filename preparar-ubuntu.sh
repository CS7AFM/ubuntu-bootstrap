#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu bootstrap para VM ou LXC.
# Configura atualizacoes automaticas, utilizador sudo, LVM, QEMU Guest Agent,
# Docker, Docker Compose e retencao do journald.

LV_PATH="/dev/ubuntu-vg/ubuntu-lv"
SUDO=""
SUDO_KEEPALIVE_PID=""
IS_CONTAINER=false
CONTAINER_TYPE="none"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mAVISO: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

on_error() {
    local exit_code=$?
    printf '\n\033[1;31mERRO: Falha na linha %s, comando: %s\033[0m\n' "$1" "$2" >&2
    exit "$exit_code"
}

trap cleanup EXIT
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# ------------------------------------------------------------
# Validacoes iniciais
# ------------------------------------------------------------

if [[ ! -r /etc/os-release ]]; then
    die "Nao foi possivel identificar o sistema operativo."
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"ubuntu"* && "${ID_LIKE:-}" != *"debian"* ]]; then
    die "Este script foi preparado para Ubuntu ou sistemas compativeis com APT. Sistema detetado: ${PRETTY_NAME:-desconhecido}."
fi

if command -v systemd-detect-virt >/dev/null 2>&1; then
    CONTAINER_TYPE="$(systemd-detect-virt --container 2>/dev/null || true)"
    if [[ -n "$CONTAINER_TYPE" && "$CONTAINER_TYPE" != "none" ]]; then
        IS_CONTAINER=true
    else
        CONTAINER_TYPE="none"
    fi
elif [[ -f /run/systemd/container || -f /.dockerenv ]]; then
    IS_CONTAINER=true
    CONTAINER_TYPE="container"
fi

# ------------------------------------------------------------
# Root ou utilizador normal com sudo
# ------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    log "Execucao como root detetada. Nao sera usada a password sudo."
    SUDO=""
else
    log "Execucao como utilizador normal: $(id -un)"

    command -v sudo >/dev/null 2>&1 || die "O comando sudo nao esta instalado. Execute como root ou instale sudo."

    printf 'Introduza a password sudo quando solicitado.\n'
    sudo -v
    SUDO="sudo"

    # Mantem a credencial sudo valida enquanto o script estiver em execucao.
    (
        while true; do
            sudo -n true
            sleep 50
            kill -0 "$$" 2>/dev/null || exit
        done
    ) &
    SUDO_KEEPALIVE_PID=$!
fi

if $IS_CONTAINER; then
    log "Ambiente de contentor detetado: ${CONTAINER_TYPE}"
    warn "A expansao LVM e o QEMU Guest Agent serao ignorados em LXC/contentor."
else
    log "Ambiente VM ou maquina fisica detetado."
fi

# ------------------------------------------------------------
# Nome do utilizador administrativo
# ------------------------------------------------------------

printf '\n=================================================\n'
printf ' Criacao de utilizador administrativo\n'
printf '=================================================\n\n'

while true; do
    read -r -p "Nome do utilizador a criar/adicionar ao grupo sudo: " ADMIN_USER
    ADMIN_USER="$(printf '%s' "$ADMIN_USER" | tr -d '[:space:]')"

    if [[ -z "$ADMIN_USER" ]]; then
        warn "O nome do utilizador nao pode estar vazio."
        continue
    fi

    if [[ ! "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        warn "Nome invalido. Use 1 a 32 caracteres: letras minusculas, numeros, _ ou -. O primeiro caracter deve ser uma letra ou _."
        continue
    fi

    if [[ "$ADMIN_USER" == "root" ]]; then
        warn "Escolha um utilizador diferente de root."
        continue
    fi

    break
done

# ------------------------------------------------------------
# APT, curl e atualizacoes automaticas
# ------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive

log "A atualizar os indices APT"
$SUDO apt-get update

log "A instalar curl, sudo e certificados CA"
$SUDO apt-get install -y curl sudo ca-certificates

log "A instalar e configurar unattended-upgrades"
$SUDO apt-get install -y unattended-upgrades

AUTO_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
if [[ -f "$AUTO_FILE" ]]; then
    $SUDO cp -a "$AUTO_FILE" "${AUTO_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi
$SUDO tee "$AUTO_FILE" >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

UU_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"
if [[ -f "$UU_FILE" ]]; then
    $SUDO cp -a "$UU_FILE" "${UU_FILE}.bak.$(date +%Y%m%d%H%M%S)"

    if $SUDO grep -Eq '^[[:space:]]*//[[:space:]]*Unattended-Upgrade::Automatic-Reboot' "$UU_FILE"; then
        $SUDO sed -i -E 's|^[[:space:]]*//[[:space:]]*(Unattended-Upgrade::Automatic-Reboot.*)|\1|' "$UU_FILE"
    elif ! $SUDO grep -Eq '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot' "$UU_FILE"; then
        printf '\nUnattended-Upgrade::Automatic-Reboot "true";\n' | $SUDO tee -a "$UU_FILE" >/dev/null
    fi
else
    warn "O ficheiro ${UU_FILE} nao existe; a opcao Automatic-Reboot nao foi alterada."
fi

$SUDO systemctl enable --now unattended-upgrades

# ------------------------------------------------------------
# Criacao do utilizador sudo
# ------------------------------------------------------------

if id "$ADMIN_USER" >/dev/null 2>&1; then
    warn "O utilizador ${ADMIN_USER} ja existe. Sera apenas adicionado ao grupo sudo."
else
    log "A criar o utilizador ${ADMIN_USER}"
    # adduser pede interativamente a password e os dados do utilizador.
    $SUDO adduser "$ADMIN_USER"
fi

log "A adicionar ${ADMIN_USER} ao grupo sudo"
$SUDO usermod -aG sudo "$ADMIN_USER"

# ------------------------------------------------------------
# Expansao LVM apenas em VM/maquina fisica
# ------------------------------------------------------------

if $IS_CONTAINER; then
    warn "Expansao LVM ignorada porque o sistema esta num contentor ${CONTAINER_TYPE}. O disco deve ser expandido no host Proxmox."
elif command -v lvs >/dev/null 2>&1 && $SUDO lvs "$LV_PATH" >/dev/null 2>&1; then
    log "A verificar espaco livre no volume group de ${LV_PATH}"

    VG_NAME="$($SUDO lvs --noheadings -o vg_name "$LV_PATH" | xargs)"
    VG_FREE_BYTES="$($SUDO vgs --noheadings --units b --nosuffix -o vg_free "$VG_NAME" | tr -d ' ')"

    if awk "BEGIN {exit !(${VG_FREE_BYTES:-0} > 0)}"; then
        log "A expandir o volume logico ${LV_PATH}"
        $SUDO lvextend -l +100%FREE "$LV_PATH"

        FS_TYPE="$(findmnt -n -o FSTYPE "$LV_PATH" 2>/dev/null || true)"
        case "$FS_TYPE" in
            ext2|ext3|ext4)
                $SUDO resize2fs "$LV_PATH"
                ;;
            xfs)
                MOUNT_POINT="$(findmnt -n -o TARGET "$LV_PATH")"
                $SUDO xfs_growfs "$MOUNT_POINT"
                ;;
            *)
                warn "Sistema de ficheiros '${FS_TYPE:-desconhecido}' nao suportado para redimensionamento automatico."
                ;;
        esac
    else
        warn "Nao existe espaco livre no volume group ${VG_NAME}; expansao LVM ignorada."
    fi
else
    warn "O volume ${LV_PATH} nao existe ou as ferramentas LVM nao estao instaladas; expansao ignorada."
fi

# ------------------------------------------------------------
# QEMU Guest Agent apenas em VM
# ------------------------------------------------------------

if $IS_CONTAINER; then
    warn "QEMU Guest Agent ignorado em LXC/contentor."
else
    log "A instalar o QEMU Guest Agent"
    $SUDO apt-get install -y qemu-guest-agent
    $SUDO systemctl enable --now qemu-guest-agent
    warn "No Proxmox, ative tambem: VM > Options > QEMU Guest Agent."
fi

# ------------------------------------------------------------
# Docker Engine
# ------------------------------------------------------------

log "A instalar o Docker Engine"
DOCKER_INSTALL_SCRIPT="$(mktemp)"
curl -fsSL https://get.docker.com -o "$DOCKER_INSTALL_SCRIPT"
$SUDO sh "$DOCKER_INSTALL_SCRIPT"
rm -f "$DOCKER_INSTALL_SCRIPT"

log "A configurar a rotacao local dos logs Docker"
$SUDO install -d -m 0755 /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
    $SUDO cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
fi

$SUDO tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

if $SUDO systemctl enable --now docker; then
    $SUDO systemctl restart docker
else
    warn "O servico Docker nao arrancou. Num LXC Proxmox confirme que Nesting e Keyctl estao ativos."
fi

# Permite ao utilizador criado executar Docker sem sudo apos novo login.
if getent group docker >/dev/null 2>&1; then
    $SUDO usermod -aG docker "$ADMIN_USER"
fi

# ------------------------------------------------------------
# Docker Compose
# ------------------------------------------------------------

log "A instalar o comando docker-compose"
$SUDO curl -L --fail \
    https://raw.githubusercontent.com/linuxserver/docker-docker-compose/master/run.sh \
    -o /usr/local/bin/docker-compose
$SUDO chmod 0755 /usr/local/bin/docker-compose

# ------------------------------------------------------------
# Journald
# ------------------------------------------------------------

log "A limitar a retencao do systemd-journald a 5 dias"
JOURNALD_FILE="/etc/systemd/journald.conf"
$SUDO cp -a "$JOURNALD_FILE" "${JOURNALD_FILE}.bak.$(date +%Y%m%d%H%M%S)"

if $SUDO grep -Eq '^[#[:space:]]*MaxRetentionSec=' "$JOURNALD_FILE"; then
    $SUDO sed -i -E 's|^[#[:space:]]*MaxRetentionSec=.*|MaxRetentionSec=5day|' "$JOURNALD_FILE"
else
    printf '\nMaxRetentionSec=5day\n' | $SUDO tee -a "$JOURNALD_FILE" >/dev/null
fi

$SUDO systemctl restart systemd-journald

# ------------------------------------------------------------
# Atualizacao opcional de containers
# ------------------------------------------------------------

if [[ -f docker-compose.yml || -f docker-compose.yaml || -f compose.yml || -f compose.yaml ]]; then
    printf '\n'
    read -r -p "Foi encontrado um ficheiro Compose. Atualizar os containers agora? [s/N] " REPLY

    if [[ "$REPLY" =~ ^[sS]$ ]]; then
        $SUDO docker-compose pull
        $SUDO docker-compose up -d --remove-orphans
        $SUDO docker image prune -f
    fi
else
    warn "Nao foi encontrado um ficheiro Compose na pasta atual; atualizacao de containers ignorada."
fi

# ------------------------------------------------------------
# Validacoes finais
# ------------------------------------------------------------

log "Validacoes finais"
printf 'Sistema: %s\n' "${PRETTY_NAME:-desconhecido}"
printf 'Ambiente: %s\n' "$([[ "$IS_CONTAINER" == true ]] && printf '%s' "$CONTAINER_TYPE" || printf 'VM/maquina fisica')"
printf 'Utilizador administrativo: %s\n' "$ADMIN_USER"
curl --version | head -n 1
docker --version
/usr/local/bin/docker-compose version || true
$SUDO systemctl --no-pager --full is-active unattended-upgrades docker || true

if ! $IS_CONTAINER; then
    $SUDO systemctl --no-pager --full is-active qemu-guest-agent || true
fi

log "Configuracao concluida"
printf '%s\n' \
    "O utilizador ${ADMIN_USER} foi adicionado aos grupos sudo e docker." \
    "Termine a sessao e volte a entrar para aplicar os novos grupos." \
    "Reinicie o sistema se o kernel ou componentes essenciais tiverem sido atualizados."

if $IS_CONTAINER; then
    printf '%s\n' "Se o Docker nao arrancar no LXC, ative Nesting e Keyctl nas opcoes do contentor no Proxmox."
else
    printf '%s\n' "Confirme no Proxmox que o QEMU Guest Agent esta ativado nas opcoes da VM."
fi
