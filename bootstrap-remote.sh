#!/usr/bin/env bash
# ParkidApp — bootstrap remoto (cliente Ubuntu). Ejecutar: sudo bash bootstrap-remote.sh
# One-liner típico:
#   curl -fsSL "$PARKIDAPP_BOOTSTRAP_URL" | sudo bash
set -euo pipefail

INSTALL_DIR="${PARKIDAPP_INSTALL_DIR:-/var/www/parkidapp-prod}"
STAGING="${PARKIDAPP_STAGING:-/tmp/parkidapp-deploy-$$}"
REPO="${PARKIDAPP_GITHUB_REPO:-}"
TAG="${PARKIDAPP_RELEASE_TAG:-latest}"
ARCHIVE_NAME="parkidapp-deploy.tar.gz"

red() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*" >&2; }
die() { red "ERROR: $*"; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Ejecutá con sudo: sudo bash $0"
}

resolve_download_url() {
  if [[ -n "${PARKIDAPP_RELEASE_URL:-}" ]]; then
    printf '%s' "${PARKIDAPP_RELEASE_URL}"
    return 0
  fi
  [[ -n "${REPO}" ]] || die "Definí PARKIDAPP_GITHUB_REPO=owner/repo o PARKIDAPP_RELEASE_URL=https://.../${ARCHIVE_NAME}"
  if [[ "${TAG}" == "latest" ]]; then
    printf 'https://github.com/%s/releases/latest/download/%s' "${REPO}" "${ARCHIVE_NAME}"
  else
    printf 'https://github.com/%s/releases/download/%s/%s' "${REPO}" "${TAG}" "${ARCHIVE_NAME}"
  fi
}

ensure_cmd() {
  local bin="$1"
  local pkgs="${2:-$1}"
  if command -v "${bin}" >/dev/null 2>&1; then
    green "OK: ${bin}"
    return 0
  fi
  yellow "Falta ${bin} — instalando ${pkgs}..."
  apt-get update -y
  # shellcheck disable=SC2086
  apt-get install -y ${pkgs}
  command -v "${bin}" >/dev/null 2>&1 || die "No se pudo instalar ${bin}"
}

verify_deps() {
  ensure_cmd curl "curl ca-certificates"
  ensure_cmd tar "tar"
  # nginx / postgresql: verificar; install.sh completa si faltan servicios
  if command -v nginx >/dev/null 2>&1; then
    green "OK: nginx"
  else
    yellow "nginx no encontrado (install.sh lo instalará si hace falta)"
  fi
  if command -v psql >/dev/null 2>&1 || dpkg -l postgresql 2>/dev/null | grep -q '^ii'; then
    green "OK: postgresql"
  else
    yellow "postgresql no encontrado (install.sh lo instalará si hace falta)"
  fi
}

preserve_runtime() {
  mkdir -p "${INSTALL_DIR}"
  # uploads y .env NO se borran: se respaldan y se restauran tras el extract/copy
  if [[ -d "${INSTALL_DIR}/uploads" ]]; then
    yellow "Preservando uploads → ${STAGING}/.preserve/uploads"
    mkdir -p "${STAGING}/.preserve"
    cp -a "${INSTALL_DIR}/uploads" "${STAGING}/.preserve/uploads"
  fi
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    yellow "Preservando .env → ${STAGING}/.preserve/.env"
    mkdir -p "${STAGING}/.preserve"
    cp -a "${INSTALL_DIR}/.env" "${STAGING}/.preserve/.env"
  fi
}

restore_runtime() {
  if [[ -d "${STAGING}/.preserve/uploads" ]]; then
    mkdir -p "${INSTALL_DIR}/uploads"
    rsync -a "${STAGING}/.preserve/uploads/" "${INSTALL_DIR}/uploads/" 2>/dev/null || \
      cp -a "${STAGING}/.preserve/uploads/." "${INSTALL_DIR}/uploads/"
  fi
  if [[ -f "${STAGING}/.preserve/.env" ]]; then
    cp -a "${STAGING}/.preserve/.env" "${INSTALL_DIR}/.env"
    chmod 600 "${INSTALL_DIR}/.env"
  fi
}

download_and_extract() {
  local url
  url="$(resolve_download_url)"
  mkdir -p "${STAGING}"
  green "Descargando ${url}"
  curl -fL --retry 3 --retry-delay 2 -o "${STAGING}/${ARCHIVE_NAME}" "${url}" \
    || die "No se pudo descargar el release (${url})"

  green "Extrayendo kit..."
  tar -xzf "${STAGING}/${ARCHIVE_NAME}" -C "${STAGING}"
  [[ -f "${STAGING}/build_assets/parkidapp-server" ]] || die "Tar inválido: falta build_assets/parkidapp-server"
  [[ -d "${STAGING}/build_assets/dist" ]] || die "Tar inválido: falta build_assets/dist"
  [[ -f "${STAGING}/installer/install.sh" ]] || die "Tar inválido: falta installer/install.sh"
}

stage_into_install_dir() {
  # Copia binario + SPA al path de producción; install.sh también copia desde build_assets.
  mkdir -p "${INSTALL_DIR}/dist" "${INSTALL_DIR}/uploads"
  cp -f "${STAGING}/build_assets/parkidapp-server" "${INSTALL_DIR}/parkidapp-server"
  chmod +x "${INSTALL_DIR}/parkidapp-server"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${STAGING}/build_assets/dist/" "${INSTALL_DIR}/dist/"
  else
    rm -rf "${INSTALL_DIR}/dist"
    cp -a "${STAGING}/build_assets/dist" "${INSTALL_DIR}/dist"
  fi
  restore_runtime
  green "Actualizado ${INSTALL_DIR} (uploads/.env preservados si existían)"
}

run_installer() {
  export PARKIDAPP_INSTALL_DIR="${INSTALL_DIR}"
  export PARKIDAPP_UNATTENDED=1
  # Si hay .env, install.sh reutiliza DB_PASSWORD y PORT; no hace falta prompt.
  if [[ -f "${INSTALL_DIR}/.env" ]] && [[ -z "${DB_PASSWORD:-}" ]]; then
    DB_PASSWORD="$(grep -E '^DB_PASSWORD=' "${INSTALL_DIR}/.env" | tail -n1 | cut -d= -f2- || true)"
    export DB_PASSWORD
  fi
  if [[ ! -f "${INSTALL_DIR}/.env" ]] && [[ -z "${DB_PASSWORD:-}" ]]; then
    die "Primera instalación: exportá DB_PASSWORD=... antes de correr el bootstrap"
  fi

  # install.sh espera DEPLOY_ROOT con build_assets/ + installer/
  bash "${STAGING}/installer/install.sh"
}

restart_pm2() {
  if ! command -v pm2 >/dev/null 2>&1; then
    yellow "pm2 no está en PATH; install.sh debió instalarlo. Saltando restart extra."
    return 0
  fi
  cd "${INSTALL_DIR}"
  pm2 restart parkidapp-backend \
    || pm2 start "${INSTALL_DIR}/parkidapp-server" --name parkidapp-backend --cwd "${INSTALL_DIR}"
  pm2 save || true
  green "PM2: parkidapp-backend activo"
}

cleanup() {
  rm -rf "${STAGING}" 2>/dev/null || true
}

main() {
  require_root
  trap cleanup EXIT
  green "=== ParkidApp bootstrap remoto → ${INSTALL_DIR} ==="
  verify_deps
  command -v rsync >/dev/null 2>&1 || apt-get install -y rsync
  download_and_extract
  preserve_runtime
  stage_into_install_dir
  run_installer
  restart_pm2
  echo
  green "Listo. UI detrás de Nginx en ${INSTALL_DIR}"
  echo "  Logs: pm2 logs parkidapp-backend"
}

main "$@"
