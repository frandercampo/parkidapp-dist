#!/usr/bin/env bash
# ParkidApp — bootstrap remoto (cliente Ubuntu). Ejecutar: sudo bash bootstrap-remote.sh
# One-liner típico:
#   curl -fsSL "$PARKIDAPP_BOOTSTRAP_URL" | sudo bash
set -euo pipefail

INSTALL_DIR="${PARKIDAPP_INSTALL_DIR:-/var/www/parkidapp-prod}"
TARGET_DIR="${INSTALL_DIR}"
STAGING="${PARKIDAPP_STAGING:-/tmp/parkidapp-deploy-$$}"
PARKIDAPP_GITHUB_REPO="${PARKIDAPP_GITHUB_REPO:-frandercampo/parkidapp-dist}"
REPO="${PARKIDAPP_GITHUB_REPO}"
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
  ensure_cmd gzip "gzip"
  # nginx / postgresql: verificar; install.sh completa si faltan servicios
  # Tailscale NO se usa: el acceso remoto es Chisel (parkid-tunnel) vía install.sh.
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
  # uploads, .env y .hwid NO se borran: se respaldan y se restauran tras el extract/copy
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
  if [[ -f "${INSTALL_DIR}/.hwid" ]]; then
    yellow "Preservando .hwid → ${STAGING}/.preserve/.hwid"
    mkdir -p "${STAGING}/.preserve"
    cp -a "${INSTALL_DIR}/.hwid" "${STAGING}/.preserve/.hwid"
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
  if [[ -f "${STAGING}/.preserve/.hwid" ]]; then
    cp -a "${STAGING}/.preserve/.hwid" "${INSTALL_DIR}/.hwid"
    chmod 600 "${INSTALL_DIR}/.hwid"
  fi
}

# Migra .env de instalaciones legacy (Node /opt o /var/www/parkidapp) → parkidapp-prod.
migrate_legacy_env() {
  if [[ -f "${TARGET_DIR}/.env" ]]; then
    return 0
  fi
  local candidate
  for candidate in \
    /var/www/parkidapp/backend/.env \
    /var/www/parkidapp/.env \
    /opt/parkidapp/.env
  do
    if [[ -f "${candidate}" ]]; then
      echo "Copiando configuración .env existente desde ${candidate}..."
      mkdir -p "${TARGET_DIR}"
      cp "${candidate}" "${TARGET_DIR}/.env"
      chmod 600 "${TARGET_DIR}/.env"
      green "Migrado ${candidate} → ${TARGET_DIR}/.env"
      return 0
    fi
  done
  yellow "No hay .env legacy que migrar."
}

ensure_db_password() {
  # Si ya hay .env en destino, install.sh / run_installer reusan DB_PASSWORD de ahí.
  if [[ -f "${TARGET_DIR}/.env" ]]; then
    return 0
  fi
  if [[ -z "${DB_PASSWORD:-}" ]] && [[ -c /dev/tty ]]; then
    # shellcheck disable=SC2162
    read -s -p "Ingrese la contraseña de PostgreSQL para la base de datos: " DB_PASSWORD < /dev/tty
    echo ""
  fi
  DB_PASSWORD="${DB_PASSWORD:-postgres}"
  export DB_PASSWORD
  yellow "Primera instalación: usando DB_PASSWORD definido (o default 'postgres')."
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
  if [[ ! -f "${STAGING}/build_assets/native/dahua/dahua_bridge" ]]; then
    yellow "Aviso: kit sin native/dahua/dahua_bridge — NetSDK no operará hasta rebuild."
  fi
}

stage_into_install_dir() {
  # Copia binario + SPA + sidecar Dahua al path de producción; install.sh también copia desde build_assets.
  mkdir -p "${INSTALL_DIR}/dist" "${INSTALL_DIR}/uploads"
  cp -f "${STAGING}/build_assets/parkidapp-server" "${INSTALL_DIR}/parkidapp-server"
  chmod +x "${INSTALL_DIR}/parkidapp-server"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${STAGING}/build_assets/dist/" "${INSTALL_DIR}/dist/"
  else
    rm -rf "${INSTALL_DIR}/dist"
    cp -a "${STAGING}/build_assets/dist" "${INSTALL_DIR}/dist"
  fi
  if [[ -d "${STAGING}/build_assets/native/dahua" ]]; then
    mkdir -p "${INSTALL_DIR}/native"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "${STAGING}/build_assets/native/dahua/" "${INSTALL_DIR}/native/dahua/"
    else
      rm -rf "${INSTALL_DIR}/native/dahua"
      cp -a "${STAGING}/build_assets/native/dahua" "${INSTALL_DIR}/native/dahua"
    fi
    chmod +x "${INSTALL_DIR}/native/dahua/dahua_bridge" 2>/dev/null || true
    if [[ -d "${INSTALL_DIR}/native/dahua/libs/linux64" ]]; then
      find "${INSTALL_DIR}/native/dahua/libs/linux64" -type f -exec chmod 755 {} +
      chmod 755 "${INSTALL_DIR}/native/dahua/libs/linux64" || true
    fi
  fi
  restore_runtime
  green "Actualizado ${INSTALL_DIR} (uploads/.env preservados si existían)"
}

run_installer() {
  export PARKIDAPP_INSTALL_DIR="${INSTALL_DIR}"
  # Desatendido: install limpia puede pedir FE/admin vía TTY; con .env existente
  # install.sh reutiliza PORT/Nginx sin bloquear la tubería.
  export PARKIDAPP_UNATTENDED=1

  migrate_legacy_env
  ensure_db_password

  # Phone-home Chisel (install.sh → setup_chisel_tunnel). Sin secret = LAN only.
  # Alias: MASTER_SECRET o INSTALLER_MASTER_SECRET (mismo valor que en el VPS).
  if [[ -n "${MASTER_SECRET:-}" ]]; then
    export MASTER_SECRET
  elif [[ -n "${INSTALLER_MASTER_SECRET:-}" ]]; then
    export MASTER_SECRET="${INSTALLER_MASTER_SECRET}"
  else
    yellow "Sin MASTER_SECRET — install.sh omitirá el túnel Chisel al VPS."
  fi
  [[ -n "${VPS_REGISTER_URL:-}" ]] && export VPS_REGISTER_URL
  [[ -n "${EMPRESA_NOMBRE:-}" ]] && export EMPRESA_NOMBRE

  # No forzar defaults de admin aquí: install.sh + lib-seed preguntan vía TTY si es limpia.
  if [[ -f "${INSTALL_DIR}/.env" ]]; then
    if [[ -z "${DB_PASSWORD:-}" ]]; then
      DB_PASSWORD="$(grep -E '^DB_PASSWORD=' "${INSTALL_DIR}/.env" | tail -n1 | cut -d= -f2- | tr -d '\r"' || true)"
      export DB_PASSWORD
    fi
    if [[ -z "${DB_USER:-}" ]]; then
      DB_USER="$(grep -E '^DB_USER=' "${INSTALL_DIR}/.env" | tail -n1 | cut -d= -f2- | tr -d '\r"' || true)"
      [[ -n "${DB_USER}" ]] && export DB_USER
    fi
  fi
  if [[ ! -f "${INSTALL_DIR}/.env" ]] && [[ -z "${DB_PASSWORD:-}" ]]; then
    die "Primera instalación: no se pudo resolver DB_PASSWORD"
  fi

  # Preservar FRONTEND_PORT/BACKEND_PORT/ADMIN_* si el operador ya los exportó.
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
  green "Repo release: ${REPO} (tag: ${TAG})"
  verify_deps
  command -v rsync >/dev/null 2>&1 || apt-get install -y rsync
  download_and_extract
  preserve_runtime
  stage_into_install_dir
  run_installer
  restart_pm2
  echo
  green "Bootstrap remoto finalizado. Revisá el resumen de install.sh arriba."
  echo "  Dir: ${INSTALL_DIR}"
  echo "  Logs: pm2 logs parkidapp-backend"
  if systemctl is-active --quiet parkid-tunnel.service 2>/dev/null; then
    echo "  Túnel: systemctl status parkid-tunnel"
  fi
}

main "$@"
