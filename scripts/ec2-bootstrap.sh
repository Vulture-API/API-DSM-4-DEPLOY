#!/usr/bin/env bash
set -euo pipefail

# Preparacao inicial de uma instancia EC2 Ubuntu 24.04 LTS para executar
# o ambiente integrado do projeto Vulture (API-DSM-4-INFRA + Docker Compose),
# orquestrado pelo repositorio dedicado API-DSM-4-DEPLOY.

if [ "$(id -u)" -ne 0 ]; then
  echo "Erro: execute este script como root (ex.: sudo $0)." >&2
  exit 1
fi

VULTURE_BASE_DIR="${VULTURE_BASE_DIR:-/opt/vulture}"
INFRA_DIR="${VULTURE_BASE_DIR}/API-DSM-4-INFRA"
DEPLOY_DIR="${VULTURE_BASE_DIR}/API-DSM-4-DEPLOY"
INFRA_REPO_URL="${INFRA_REPO_URL:-https://github.com/Vulture-API/API-DSM-4-INFRA.git}"
INFRA_BRANCH="${INFRA_BRANCH:-main}"
DEPLOY_REPO_URL="${DEPLOY_REPO_URL:-https://github.com/Vulture-API/API-DSM-4-DEPLOY.git}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"

echo "==> [1/6] Configurando swap de 2 GB (se necessario)..."
if ! swapon --show | grep -q '/swapfile'; then
  if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >>/etc/fstab
  fi
  echo "Swap de 2 GB ativado."
else
  echo "Swap ja ativo, mantendo configuracao atual."
fi

echo "==> [2/6] Instalando dependencias base do sistema..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git gnupg jq openssl python3 python3-venv

if ! command -v docker >/dev/null 2>&1; then
  echo "==> [3/6] Instalando Docker Engine e Docker Compose v2..."
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "==> [3/6] Docker ja instalado: $(docker --version)"
fi

mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  cat <<'EOF' >/etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
fi

systemctl enable docker
systemctl restart docker

for usr in ubuntu ssm-user; do
  if id "$usr" >/dev/null 2>&1; then
    usermod -aG docker "$usr" || true
  fi
done

echo "==> [4/6] Verificando AWS Systems Manager (SSM Agent)..."
if systemctl list-unit-files | grep -q 'snap.amazon-ssm-agent.amazon-ssm-agent.service'; then
  systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true
elif systemctl list-unit-files | grep -q 'amazon-ssm-agent.service'; then
  systemctl enable --now amazon-ssm-agent.service || true
else
  echo "Aviso: servico amazon-ssm-agent nao detectado via systemd; valide no console AWS se a instancia esta online no Fleet Manager."
fi

echo "==> [5/6] Preparando diretorios e repositorios em ${VULTURE_BASE_DIR}..."
mkdir -p "${VULTURE_BASE_DIR}/scripts"

if [ ! -d "${INFRA_DIR}/.git" ]; then
  git clone --branch "${INFRA_BRANCH}" --recurse-submodules "${INFRA_REPO_URL}" "${INFRA_DIR}"
else
  git -C "${INFRA_DIR}" fetch origin "${INFRA_BRANCH}"
  git -C "${INFRA_DIR}" checkout "${INFRA_BRANCH}"
  git -C "${INFRA_DIR}" submodule sync --recursive
  git -C "${INFRA_DIR}" submodule update --init --recursive
fi

# O workflow de deploy atualiza este clone a cada execucao: ele precisa existir
# mesmo quando o bootstrap roda a partir de uma copia local do repositorio.
if [ ! -d "${DEPLOY_DIR}/.git" ]; then
  git clone --branch "${DEPLOY_BRANCH}" "${DEPLOY_REPO_URL}" "${DEPLOY_DIR}"
else
  git -C "${DEPLOY_DIR}" fetch origin "${DEPLOY_BRANCH}"
  git -C "${DEPLOY_DIR}" checkout "${DEPLOY_BRANCH}"
  git -C "${DEPLOY_DIR}" reset --hard "origin/${DEPLOY_BRANCH}"
fi
COMPOSE_AWS_SRC="${DEPLOY_DIR}/aws/docker-compose.aws.yml"
DEPLOY_SH_SRC="${DEPLOY_DIR}/scripts/deploy-ec2.sh"

cp "${COMPOSE_AWS_SRC}" "${VULTURE_BASE_DIR}/scripts/docker-compose.aws.yml"
cp "${COMPOSE_AWS_SRC}" "${INFRA_DIR}/docker-compose.aws.yml"
cp "${DEPLOY_SH_SRC}" "${VULTURE_BASE_DIR}/scripts/deploy-ec2.sh"
chmod 750 "${VULTURE_BASE_DIR}/scripts/deploy-ec2.sh"

echo "==> [6/6] Inicializando arquivo .env de producao..."
ENV_FILE="${INFRA_DIR}/.env"
if [ ! -f "${ENV_FILE}" ]; then
  cp "${INFRA_DIR}/.env.example" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"

  GENERATED_JWT="$(openssl rand -hex 32)"
  GENERATED_SOURCE_ID="vulture-aws-prod-$(openssl rand -hex 6)"

  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${GENERATED_JWT}|" "${ENV_FILE}"
  sed -i "s|^PERSIST_SOURCE_ID=.*|PERSIST_SOURCE_ID=${GENERATED_SOURCE_ID}|" "${ENV_FILE}"

  echo "Arquivo ${ENV_FILE} criado com JWT_SECRET e PERSIST_SOURCE_ID gerados automaticamente."
else
  chmod 600 "${ENV_FILE}"
  echo "Arquivo ${ENV_FILE} ja existe e foi preservado."
fi

cat <<EOF

Bootstrap concluido com sucesso!
Proximos passos obrigatorios antes do primeiro deploy:
  1. Edite ${ENV_FILE} e configure o DATABASE_URL real do PostgreSQL externo (RDS ou Neon).
     Nao altere o PERSIST_SOURCE_ID apos a primeira ativacao do Redis/persistencia.
  2. Garanta que as migrations do repositorio API-DSM-4-BANCO ja foram aplicadas no banco.
  3. Teste manualmente o primeiro deploy com:
     sudo ${VULTURE_BASE_DIR}/scripts/deploy-ec2.sh
EOF
