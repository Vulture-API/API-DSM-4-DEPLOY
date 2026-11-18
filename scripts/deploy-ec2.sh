#!/usr/bin/env bash
set -euo pipefail

# Script de deploy continuo executado dentro da instancia EC2 (via SSM ou SSH).
# Atualiza o repositorio API-DSM-4-INFRA mantendo os submodulos nos commits fixados,
# sobe os servicos com Docker Compose e realiza a ativacao segura da persistencia.

VULTURE_BASE_DIR="${VULTURE_BASE_DIR:-/opt/vulture}"
INFRA_DIR="${INFRA_DIR:-${VULTURE_BASE_DIR}/API-DSM-4-INFRA}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-vulture}"
AWS_OVERRIDE_FILE="${AWS_OVERRIDE_FILE:-${INFRA_DIR}/docker-compose.aws.yml}"
ENV_FILE="${INFRA_DIR}/.env"

if [ ! -d "${INFRA_DIR}/.git" ]; then
  echo "Erro: repositorio de infraestrutura nao encontrado em ${INFRA_DIR}. Execute ec2-bootstrap.sh primeiro." >&2
  exit 1
fi

cd "${INFRA_DIR}"

if [ ! -f "${AWS_OVERRIDE_FILE}" ]; then
  if [ -f "${VULTURE_BASE_DIR}/scripts/docker-compose.aws.yml" ]; then
    cp "${VULTURE_BASE_DIR}/scripts/docker-compose.aws.yml" "${AWS_OVERRIDE_FILE}"
  else
    echo "Erro: arquivo de override ${AWS_OVERRIDE_FILE} nao encontrado." >&2
    exit 1
  fi
fi

if [ ! -f "${ENV_FILE}" ]; then
  echo "Erro: arquivo ${ENV_FILE} nao encontrado." >&2
  exit 1
fi

get_env_val() {
  local key="$1"
  local line
  line="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%$'\r'}"
  line="${line#\"}"
  line="${line%\"}"
  line="${line#\'}"
  line="${line%\'}"
  printf '%s' "${line}"
}

DB_URL="$(get_env_val "DATABASE_URL")"
JWT_VAL="$(get_env_val "JWT_SECRET")"
SOURCE_ID_VAL="$(get_env_val "PERSIST_SOURCE_ID")"
BACKEND_PORT_VAL="$(get_env_val "BACKEND_PORT")"
BACKEND_PORT_VAL="${BACKEND_PORT_VAL:-3000}"

if [ -z "${DB_URL}" ] || [ "${DB_URL}" = "postgresql://usuario:senha@endereco/banco" ]; then
  echo "Erro: DATABASE_URL nao esta configurada com o banco real em ${ENV_FILE}." >&2
  exit 1
fi

if [ "${#JWT_VAL}" -lt 32 ]; then
  echo "Erro: JWT_SECRET deve possuir ao menos 32 caracteres em ${ENV_FILE}." >&2
  exit 1
fi

if [ -z "${SOURCE_ID_VAL}" ]; then
  echo "Erro: PERSIST_SOURCE_ID obrigatorio e nao pode ficar vazio em ${ENV_FILE}." >&2
  exit 1
fi

echo "==> [1/5] Sincronizando API-DSM-4-INFRA (branch ${DEPLOY_BRANCH}) e submodulos fixados..."
git fetch origin "${DEPLOY_BRANCH}"
git checkout "${DEPLOY_BRANCH}"
git reset --hard "origin/${DEPLOY_BRANCH}"
git submodule sync --recursive
# Nunca usar --remote em producao: os commits dos servicos sao fixados pelo repositorio INFRA.
git submodule update --init --recursive

if [ ! -f "${AWS_OVERRIDE_FILE}" ] && [ -f "${VULTURE_BASE_DIR}/scripts/docker-compose.aws.yml" ]; then
  cp "${VULTURE_BASE_DIR}/scripts/docker-compose.aws.yml" "${AWS_OVERRIDE_FILE}"
fi

echo "Revisao INFRA em deploy: $(git rev-parse --short HEAD)"
git submodule status

DEPLOY_DIR="${DEPLOY_DIR:-${VULTURE_BASE_DIR}/API-DSM-4-DEPLOY}"
if [ -f "${DEPLOY_DIR}/aws/docker-compose.aws.yml" ]; then
  cp "${DEPLOY_DIR}/aws/docker-compose.aws.yml" "${AWS_OVERRIDE_FILE}"
fi

echo "==> [1.5/5] Garantindo certificado HTTPS (Let's Encrypt) e configuracao do Nginx..."
PUBLIC_DOMAIN="$(get_env_val "PUBLIC_DOMAIN")"
if [ -z "${PUBLIC_DOMAIN}" ]; then
  IMDS_TOKEN="$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)"
  PUBLIC_IP="$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  if [ -z "${PUBLIC_IP}" ]; then
    echo "Erro: nao foi possivel descobrir o IP publico. Defina PUBLIC_DOMAIN em ${ENV_FILE}." >&2
    exit 1
  fi
  PUBLIC_DOMAIN="${PUBLIC_IP//./-}.sslip.io"
fi
CERTBOT_EMAIL="$(get_env_val "CERTBOT_EMAIL")"
echo "Dominio publico: ${PUBLIC_DOMAIN}"

if ! command -v certbot >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot
fi

NGINX_CONTAINER="${COMPOSE_PROJECT}-nginx-1"
install -d -m 755 /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
printf '#!/bin/sh\ndocker stop %s >/dev/null 2>&1 || true\n' "${NGINX_CONTAINER}" > /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh
printf '#!/bin/sh\ndocker start %s >/dev/null 2>&1 || true\n' "${NGINX_CONTAINER}" > /etc/letsencrypt/renewal-hooks/post/start-nginx.sh
chmod 755 /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh /etc/letsencrypt/renewal-hooks/post/start-nginx.sh

if [ ! -f "/etc/letsencrypt/live/${PUBLIC_DOMAIN}/fullchain.pem" ]; then
  if [ -n "${CERTBOT_EMAIL}" ]; then
    EMAIL_ARGS=(--email "${CERTBOT_EMAIL}")
  else
    EMAIL_ARGS=(--register-unsafely-without-email)
  fi
  docker stop "${NGINX_CONTAINER}" >/dev/null 2>&1 || true
  certbot certonly --standalone --non-interactive --agree-tos "${EMAIL_ARGS[@]}" -d "${PUBLIC_DOMAIN}"
fi

sed "s/__PUBLIC_DOMAIN__/${PUBLIC_DOMAIN}/g" "${DEPLOY_DIR}/aws/nginx.aws.conf" > "${INFRA_DIR}/nginx/nginx.aws.generated.conf"

echo "==> [2/5] Construindo e atualizando servicos base com Docker Compose..."
docker compose \
  --project-name "${COMPOSE_PROJECT}" \
  --env-file "${ENV_FILE}" \
  -f docker-compose.yml \
  -f "${AWS_OVERRIDE_FILE}" \
  up -d --build --wait --wait-timeout 180 \
  mosquitto redis recepcao backend frontend nginx

docker exec "${NGINX_CONTAINER}" nginx -s reload

echo "==> [3/5] Ativando servico de persistencia com validacao de schema e Stream Redis..."
mkdir -p reports
python3 scripts/telemetry.py activate \
  --project "${COMPOSE_PROJECT}" \
  --evidence reports/activation.json

echo "==> [4/5] Executando Smoke Tests locais na EC2..."
check_endpoint() {
  local label="$1"
  local url="$2"
  local max_status="$3"
  local status="000"

  for attempt in $(seq 1 12); do
    status="$(curl -s -o /dev/null -w "%{http_code}" "${url}" || true)"
    if [ "${status}" -ge 200 ] && [ "${status}" -lt "${max_status}" ]; then
      echo "[OK] ${label} (${url}) respondeu HTTP ${status} na tentativa ${attempt}."
      return 0
    fi
    echo "[Aguardando] ${label} retornou HTTP ${status} (tentativa ${attempt}/12)..."
    sleep 5
  done

  echo "Erro: ${label} falhou no Smoke Test local (ultimo HTTP ${status})." >&2
  return 1
}

check_endpoint "Backend /health" "http://127.0.0.1:${BACKEND_PORT_VAL}/health" 300
check_endpoint "Nginx/Frontend /dashboard" "http://127.0.0.1:80/dashboard" 500

echo "==> [5/5] Removendo imagens Docker orfas (volumes e dados preservados)..."
docker image prune -f

echo "Deploy na EC2 concluido com sucesso!"
