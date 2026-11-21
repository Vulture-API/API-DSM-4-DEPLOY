#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Testes das validacoes do deploy-ec2.sh (sem Docker, git ou AWS).

setup() {
  ENV_FILE="$(mktemp)"
  export ENV_FILE
  # shellcheck source=../scripts/deploy-ec2.sh
  source "${BATS_TEST_DIRNAME}/../scripts/deploy-ec2.sh"
  set +Eu +o pipefail
  trap - ERR
}

teardown() {
  rm -f "${ENV_FILE}"
}

env_ok() {
  cat >"${ENV_FILE}" <<'ENV'
DATABASE_URL=postgresql://user:pass@host/db
JWT_SECRET=0123456789abcdef0123456789abcdef
PERSIST_SOURCE_ID=vulture-aws-prod-abc
ENV
}

@test "get_env_val remove aspas e CRLF e usa a ultima ocorrencia" {
  printf 'A=1\nA="segundo"\r\nB='"'"'x y'"'"'\n' >"${ENV_FILE}"
  [ "$(get_env_val A)" = "segundo" ]
  [ "$(get_env_val B)" = "x y" ]
  [ "$(get_env_val NAO_EXISTE)" = "" ]
}

@test "validate_env aceita .env completo" {
  env_ok
  run validate_env
  [ "$status" -eq 0 ]
}

@test "validate_env recusa DATABASE_URL de exemplo" {
  env_ok
  sed -i 's|^DATABASE_URL=.*|DATABASE_URL=postgresql://usuario:senha@endereco/banco|' "${ENV_FILE}"
  run validate_env
  [ "$status" -ne 0 ]
  [[ "$output" == *DATABASE_URL* ]]
}

@test "validate_env recusa JWT_SECRET curto" {
  env_ok
  sed -i 's|^JWT_SECRET=.*|JWT_SECRET=curto|' "${ENV_FILE}"
  run validate_env
  [ "$status" -ne 0 ]
  [[ "$output" == *JWT_SECRET* ]]
}

@test "validate_env recusa PERSIST_SOURCE_ID vazio" {
  env_ok
  sed -i 's|^PERSIST_SOURCE_ID=.*|PERSIST_SOURCE_ID=|' "${ENV_FILE}"
  run validate_env
  [ "$status" -ne 0 ]
  [[ "$output" == *PERSIST_SOURCE_ID* ]]
}

@test "validate_env recusa .env ausente" {
  rm -f "${ENV_FILE}"
  run validate_env
  [ "$status" -ne 0 ]
}

@test "validate_sha aceita SHA completo e abreviado" {
  validate_sha 9e75308
  validate_sha 9e753083c1b0f6f4e1e8a8b7d5c4b3a2a1b0c9d8
}

@test "validate_sha recusa entrada invalida" {
  run ! validate_sha 9e7530
  run ! validate_sha 'main'
  run ! validate_sha '9e75308; rm -rf /'
  run ! validate_sha 9E75308
}

@test "validate_domain aceita sslip.io e dominio proprio" {
  validate_domain 3-91-10-20.sslip.io
  validate_domain vulture.example.com
}

@test "validate_domain recusa caracteres de shell e maiusculas" {
  run ! validate_domain 'a.com; reboot'
  run ! validate_domain 'a.com/x'
  run ! validate_domain 'Vulture.com'
  run ! validate_domain ''
}
