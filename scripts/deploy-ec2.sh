#!/usr/bin/env bash
set -Eeuo pipefail

# Script de deploy continuo executado dentro da instancia EC2 (via SSM ou SSH).
# Publica um commit exato do API-DSM-4-INFRA (INFRA_SHA, ja aprovado no E2E),
# mantendo os submodulos nos commits fixados por ele. Se algo falhar depois de
# trocar a versao, volta para o commit anterior e sobe os servicos de novo.

VULTURE_BASE_DIR="${VULTURE_BASE_DIR:-/opt/vulture}"
INFRA_DIR="${INFRA_DIR:-${VULTURE_BASE_DIR}/API-DSM-4-INFRA}"
DEPLOY_DIR="${DEPLOY_DIR:-${VULTURE_BASE_DIR}/API-DSM-4-DEPLOY}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-vulture}"
AWS_OVERRIDE_FILE="${AWS_OVERRIDE_FILE:-${INFRA_DIR}/docker-compose.aws.yml}"
ENV_FILE="${ENV_FILE:-${INFRA_DIR}/.env}"
NGINX_CONTAINER="${COMPOSE_PROJECT}-nginx-1"
BASE_SERVICES=(mosquitto redis recepcao backend frontend nginx)

PREV_SHA=""
ROLLBACK_ARMED="false"

log() { printf '%s\n' "$*"; }
die() {
  printf 'Erro: %s\n' "$*" >&2
  exit 1
}

# Le KEY=valor do .env sem executar o arquivo (aceita aspas e fim de linha CRLF).
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

validate_env() {
  [ -f "${ENV_FILE}" ] || die "arquivo ${ENV_FILE} nao encontrado."

  local db_url jwt source_id
  db_url="$(get_env_val "DATABASE_URL")"
  jwt="$(get_env_val "JWT_SECRET")"
  source_id="$(get_env_val "PERSIST_SOURCE_ID")"

  if [ -z "${db_url}" ] || [ "${db_url}" = "postgresql://usuario:senha@endereco/banco" ]; then
    die "DATABASE_URL nao esta configurada com o banco real em ${ENV_FILE}."
  fi
  [ "${#jwt}" -ge 32 ] || die "JWT_SECRET deve possuir ao menos 32 caracteres em ${ENV_FILE}."
  [ -n "${source_id}" ] || die "PERSIST_SOURCE_ID obrigatorio e nao pode ficar vazio em ${ENV_FILE}."
}

# Aceita SHA completo ou abreviado (7+ caracteres hexadecimais).
validate_sha() {
  [[ "$1" =~ ^[0-9a-f]{7,40}$ ]]
}

# Nome DNS simples: letras minusculas, numeros, ponto e hifen.
validate_domain() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ ]]
}

compose() {
  docker compose \
    --project-name "${COMPOSE_PROJECT}" \
    --env-file "${ENV_FILE}" \
    -f docker-compose.yml \
    -f "${AWS_OVERRIDE_FILE}" \
    "$@"
}

checkout_infra() {
  local sha="$1"
  git checkout -q -f --detach "${sha}"
  git submodule sync --recursive
  # Nunca usar --remote em producao: os commits dos servicos sao fixados pelo INFRA.
  git submodule update --init --recursive --force
}

copy_override() {
  if [ -f "${DEPLOY_DIR}/aws/docker-compose.aws.yml" ]; then
    cp "${DEPLOY_DIR}/aws/docker-compose.aws.yml" "${AWS_OVERRIDE_FILE}"
  elif [ -f "${VULTURE_BASE_DIR}/scripts/docker-compose.aws.yml" ]; then
    cp "${VULTURE_BASE_DIR}/scripts/docker-compose.aws.yml" "${AWS_OVERRIDE_FILE}"
  fi
  [ -f "${AWS_OVERRIDE_FILE}" ] || die "arquivo de override ${AWS_OVERRIDE_FILE} nao encontrado."
}

resolve_public_domain() {
  local domain="${PUBLIC_DOMAIN:-$(get_env_val "PUBLIC_DOMAIN")}"
  if [ -z "${domain}" ]; then
    local token ip
    token="$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)"
    ip="$(curl -s -H "X-aws-ec2-metadata-token: ${token}" http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
    [ -n "${ip}" ] || die "nao foi possivel descobrir o IP publico. Defina PUBLIC_DOMAIN em ${ENV_FILE}."
    domain="${ip//./-}.sslip.io"
  fi
  validate_domain "${domain}" || die "PUBLIC_DOMAIN invalido: ${domain}"
  printf '%s' "${domain}"
}

ensure_certificate() {
  local domain="$1"
  local email
  email="$(get_env_val "CERTBOT_EMAIL")"

  if ! command -v certbot >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot
  fi

  install -d -m 755 /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
  printf '#!/bin/sh\ndocker stop %s >/dev/null 2>&1 || true\n' "${NGINX_CONTAINER}" >/etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh
  printf '#!/bin/sh\ndocker start %s >/dev/null 2>&1 || true\n' "${NGINX_CONTAINER}" >/etc/letsencrypt/renewal-hooks/post/start-nginx.sh
  chmod 755 /etc/letsencrypt/renewal-hooks/pre/stop-nginx.sh /etc/letsencrypt/renewal-hooks/post/start-nginx.sh

  if [ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
    local email_args=(--register-unsafely-without-email)
    [ -z "${email}" ] || email_args=(--email "${email}")
    docker stop "${NGINX_CONTAINER}" >/dev/null 2>&1 || true
    certbot certonly --standalone --non-interactive --agree-tos "${email_args[@]}" -d "${domain}"
  fi

  sed "s/__PUBLIC_DOMAIN__/${domain}/g" "${DEPLOY_DIR}/aws/nginx.aws.conf" >"${INFRA_DIR}/nginx/nginx.aws.generated.conf"
}

start_services() {
  compose up -d --build --wait --wait-timeout 180 "${BASE_SERVICES[@]}"
  docker exec "${NGINX_CONTAINER}" nginx -s reload
  mkdir -p reports
  python3 scripts/telemetry.py activate \
    --project "${COMPOSE_PROJECT}" \
    --evidence reports/activation.json
}

retry() {
  local label="$1"
  shift
  local attempt
  for attempt in $(seq 1 12); do
    if "$@" >/dev/null 2>&1; then
      log "[OK] ${label} (tentativa ${attempt})."
      return 0
    fi
    log "[Aguardando] ${label} (tentativa ${attempt}/12)..."
    sleep 5
  done
  printf 'Erro: %s falhou no smoke test local.\n' "${label}" >&2
  return 1
}

smoke_tests() {
  local domain="$1"
  local backend_port
  backend_port="$(get_env_val "BACKEND_PORT")"
  backend_port="${backend_port:-3000}"

  retry "Backend /health" curl -fsS "http://127.0.0.1:${backend_port}/health"
  # Dentro do container o nginx ve 127.0.0.1 e repassa ao frontend (do host ele
  # responderia 301 e o teste passaria sem tocar no frontend).
  retry "Nginx -> Frontend /dashboard" docker exec "${NGINX_CONTAINER}" wget -q --spider http://127.0.0.1/dashboard
  # Caminho real do usuario: HTTPS com o certificado do dominio publico.
  retry "HTTPS ${domain}/dashboard" curl -fsS -o /dev/null --resolve "${domain}:443:127.0.0.1" "https://${domain}/dashboard"
  retry "HTTPS ${domain}/health" curl -fsS -o /dev/null --resolve "${domain}:443:127.0.0.1" "https://${domain}/health"
}

rollback() {
  local status=$?
  # Com errtrace o trap tambem chega a subshells: so o processo principal volta a versao.
  [ "${BASHPID}" = "$$" ] || exit "${status}"
  [ "${ROLLBACK_ARMED}" = "true" ] || exit "${status}"
  ROLLBACK_ARMED="false"
  trap - ERR
  set +e
  printf 'Erro no deploy (codigo %s). Voltando para o INFRA %s...\n' "${status}" "${PREV_SHA:0:7}" >&2
  cd "${INFRA_DIR}" || exit "${status}"
  checkout_infra "${PREV_SHA}" && start_services
  local rb=$?
  if [ "${rb}" -eq 0 ]; then
    printf 'Rollback concluido: servicos no INFRA %s.\n' "${PREV_SHA:0:7}" >&2
  else
    printf 'ROLLBACK FALHOU (codigo %s): verificar a EC2 manualmente.\n' "${rb}" >&2
  fi
  exit "${status}"
}

main() {
  [ -d "${INFRA_DIR}/.git" ] || die "repositorio de infraestrutura nao encontrado em ${INFRA_DIR}. Execute ec2-bootstrap.sh primeiro."
  cd "${INFRA_DIR}"
  validate_env

  log "==> [1/6] Resolvendo a versao do API-DSM-4-INFRA..."
  git fetch -q origin "${DEPLOY_BRANCH}"
  local target="${INFRA_SHA:-}"
  if [ -z "${target}" ]; then
    target="$(git rev-parse "origin/${DEPLOY_BRANCH}")"
    log "INFRA_SHA nao informado: usando a ponta de origin/${DEPLOY_BRANCH}."
  fi
  validate_sha "${target}" || die "INFRA_SHA invalido: ${target}"
  target="$(git rev-parse --verify "${target}^{commit}")" || die "commit ${target} nao existe no INFRA."
  git merge-base --is-ancestor "${target}" "origin/${DEPLOY_BRANCH}" ||
    die "commit ${target} nao pertence a origin/${DEPLOY_BRANCH} do INFRA."

  PREV_SHA="$(git rev-parse HEAD)"
  log "Versao atual: ${PREV_SHA:0:7} -> nova: ${target:0:7}"

  ROLLBACK_ARMED="true"
  trap rollback ERR

  log "==> [2/6] Trocando para o INFRA ${target:0:7} e submodulos fixados..."
  checkout_infra "${target}"
  git submodule status
  copy_override

  log "==> [3/6] Certificado HTTPS e configuracao do Nginx..."
  local domain
  domain="$(resolve_public_domain)"
  log "Dominio publico: ${domain}"
  ensure_certificate "${domain}"

  log "==> [4/6] Build, subida dos servicos e ativacao da persistencia..."
  start_services

  log "==> [5/6] Smoke tests locais..."
  smoke_tests "${domain}"

  ROLLBACK_ARMED="false"
  trap - ERR

  log "==> [6/6] Removendo imagens Docker orfas (volumes e dados preservados)..."
  docker image prune -f

  log "Deploy concluido: INFRA ${target:0:7} em ${domain}."
}

# Permite carregar as funcoes nos testes (bats) sem executar o deploy.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
