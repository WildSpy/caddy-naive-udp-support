#!/usr/bin/env bash
set -euo pipefail

CADDY_SERVICE="caddy-naive"
CADDY_BIN="/usr/local/bin/caddy-naive"
BUILD_DIR="/root"
NEW_CADDY="${BUILD_DIR}/caddy"
XCADDY="${XCADDY:-}"

# Вариант forwardproxy: awow (aUsernameWoW/forwardproxy@naive) или zedifen (zedifen/forwardproxy@naive)
FORWARDPROXY="${FORWARDPROXY:-}"
ZEDIFEN_REPO="https://github.com/zedifen/forwardproxy.git"
ZEDIFEN_BRANCH="${ZEDIFEN_BRANCH:-naive}"
ZEDIFEN_DIR="${BUILD_DIR}/forwardproxy-zedifen"

# Целевая платформа (по умолчанию определяется автоматически)
TARGET_OS="${TARGET_OS:-linux}"
TARGET_ARCH="${TARGET_ARCH:-}"
TARGET_ARM="${TARGET_ARM:-}"

CADDY_CONFIG="${CADDY_CONFIG:-/etc/caddy-naive/Caddyfile}"
CADDY_ADAPTER="${CADDY_ADAPTER:-caddyfile}"

BACKUP_SUFFIX="_old_$(date +%Y%m%d-%H%M%S)"
OLD_BACKUP="${CADDY_BIN}${BACKUP_SUFFIX}"
CONFIG_BACKUP="${CADDY_CONFIG}${BACKUP_SUFFIX}"
# Конфиг, подготовленный для нового бинарника (пусто, если менять конфиг не нужно)
NEW_CONFIG=""

# Опции aUsernameWoW, которых нет в zedifen: там CONNECT-UDP и UoT работают всегда
ZEDIFEN_UNSUPPORTED_OPTIONS='udp_uri_template|passthrough_uot'

log() {
  echo -e "\033[0;32m[INFO]\033[0m $*"
}

warn() {
  echo -e "\033[1;33m[WARN]\033[0m $*"
}

err() {
  echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
}

usage() {
  echo "Использование: sudo bash enable-naive-udp.sh [awow|zedifen]"
  echo ""
  echo "  awow     - github.com/aUsernameWoW/forwardproxy@naive"
  echo "  zedifen  - github.com/zedifen/forwardproxy@naive (Caddy с патчем sing-quic BBRv1)"
  echo ""
  echo "Переменные окружения: FORWARDPROXY, CADDY_CONFIG, CADDY_ADAPTER, TARGET_OS, TARGET_ARCH, TARGET_ARM, XCADDY, ZEDIFEN_BRANCH"
}

choose_forwardproxy() {
  if [[ $# -gt 0 ]]; then
    FORWARDPROXY="$1"
  fi

  if [[ -z "$FORWARDPROXY" ]]; then
    # Читаем из /dev/tty, чтобы меню работало и при запуске через curl ... | bash
    if ! { : </dev/tty; } 2>/dev/null; then
      err "Нет терминала для выбора. Передай аргумент awow|zedifen или FORWARDPROXY=..."
      exit 1
    fi

    echo ""
    echo "Выбери версию forwardproxy:"
    echo "  1) aUsernameWoW/forwardproxy@naive"
    echo "  2) zedifen/forwardproxy@naive (Caddy с патчем sing-quic BBRv1)"
    echo ""

    local answer
    while true; do
      read -rp "Вариант [1/2, по умолчанию 1]: " answer </dev/tty
      case "${answer:-1}" in
        1) FORWARDPROXY="awow"; break ;;
        2) FORWARDPROXY="zedifen"; break ;;
        *) warn "Неизвестный вариант: $answer. Введи 1 или 2" ;;
      esac
    done
  fi

  case "$FORWARDPROXY" in
    awow|aUsernameWoW) FORWARDPROXY="awow" ;;
    zedifen) ;;
    -h|--help) usage; exit 0 ;;
    *) err "Неизвестный вариант forwardproxy: $FORWARDPROXY"; usage; exit 1 ;;
  esac

  log "Выбран forwardproxy: $FORWARDPROXY"
}

detect_platform() {
  if [[ -z "$TARGET_ARCH" ]]; then
    case "$(uname -m)" in
      x86_64|amd64) TARGET_ARCH="amd64" ;;
      aarch64|arm64) TARGET_ARCH="arm64" ;;
      armv7l|armv7*) TARGET_ARCH="arm"; TARGET_ARM="${TARGET_ARM:-7}" ;;
      armv6l|armv6*) TARGET_ARCH="arm"; TARGET_ARM="${TARGET_ARM:-6}" ;;
      i386|i686) TARGET_ARCH="386" ;;
      s390x) TARGET_ARCH="s390x" ;;
      ppc64le) TARGET_ARCH="ppc64le" ;;
      riscv64) TARGET_ARCH="riscv64" ;;
      *)
        err "Неизвестная архитектура: $(uname -m). Укажи TARGET_ARCH вручную"
        exit 1
        ;;
    esac
  fi

  export GOOS="$TARGET_OS"
  export GOARCH="$TARGET_ARCH"
  if [[ "$TARGET_ARCH" == "arm" && -n "$TARGET_ARM" ]]; then
    export GOARM="$TARGET_ARM"
  fi

  log "Целевая платформа: ${GOOS}/${GOARCH}${GOARM:+ (GOARM=$GOARM)}"
}

need_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "Запусти скрипт от root: sudo bash enable-naive-udp.sh"
    exit 1
  fi
}

install_go_if_needed() {
  if command -v go >/dev/null 2>&1; then
    log "Go найден: $(go version)"
    return
  fi

  log "Go не найден, пробуем установить"

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y golang-go
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y golang
  elif command -v yum >/dev/null 2>&1; then
    yum install -y golang
  else
    err "Не удалось установить Go автоматически: не найден apt-get, dnf или yum"
    echo ""
    echo "Установи Go вручную и запусти скрипт снова."
    exit 1
  fi

  if ! command -v go >/dev/null 2>&1; then
    err "Go был установлен, но команда go всё ещё не найдена"
    exit 1
  fi

  log "Go установлен: $(go version)"
}

install_git_if_needed() {
  if command -v git >/dev/null 2>&1; then
    log "git найден: $(git --version)"
    return
  fi

  log "git не найден, пробуем установить"

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y git
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git
  elif command -v yum >/dev/null 2>&1; then
    yum install -y git
  else
    err "Не удалось установить git автоматически: не найден apt-get, dnf или yum"
    exit 1
  fi

  if ! command -v git >/dev/null 2>&1; then
    err "git был установлен, но команда git всё ещё не найдена"
    exit 1
  fi
}

check_go_toolchain_support() {
  # zedifen требует Go >= 1.26. Go >= 1.21 сам скачает нужный toolchain (GOTOOLCHAIN=auto)
  local ver major minor
  ver="$(go env GOVERSION)"
  ver="${ver#go}"
  major="${ver%%.*}"
  minor="${ver#*.}"
  minor="${minor%%.*}"

  if (( major < 1 || (major == 1 && minor < 21) )); then
    err "Для zedifen нужен Go >= 1.26 (или >= 1.21 для автозагрузки toolchain), найден: $(go version)"
    echo ""
    echo "Установи свежий Go с https://go.dev/dl/ и запусти скрипт снова."
    exit 1
  fi

  export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
}

install_xcaddy_if_needed() {
  if [[ -n "$XCADDY" && -x "$XCADDY" ]]; then
    log "xcaddy найден: $XCADDY"
    return
  fi

  if command -v xcaddy >/dev/null 2>&1; then
    XCADDY="$(command -v xcaddy)"
    log "xcaddy найден: $XCADDY"
    return
  fi

  local gopath
  gopath="$(go env GOPATH)"
  XCADDY="${gopath}/bin/xcaddy"

  if [[ -x "$XCADDY" ]]; then
    log "xcaddy найден: $XCADDY"
    return
  fi

  log "xcaddy не найден, устанавливаем через go install"

  # xcaddy запускается на этой машине, поэтому собираем его под хост, а не под TARGET_*
  env -u GOOS -u GOARCH -u GOARM go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

  if [[ ! -x "$XCADDY" ]]; then
    err "xcaddy был установлен, но бинарник не найден или не исполняемый: $XCADDY"
    exit 1
  fi

  log "xcaddy установлен: $XCADDY"
}

check_requirements() {
  log "Проверяем зависимости"

  install_go_if_needed

  if [[ "$FORWARDPROXY" == "zedifen" ]]; then
    install_git_if_needed
    check_go_toolchain_support
  fi

  install_xcaddy_if_needed

  if [[ ! -f "$CADDY_BIN" ]]; then
    err "Не найден текущий caddy-naive: $CADDY_BIN"
    exit 1
  fi

  if [[ ! -f "$CADDY_CONFIG" ]]; then
    err "Не найден конфиг: $CADDY_CONFIG (укажи путь через CADDY_CONFIG=...)"
    exit 1
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    err "systemctl не найден"
    exit 1
  fi

  log "OK"
}

build_awow() {
  log "Собираем Caddy с aUsernameWoW/forwardproxy@naive"

  "$XCADDY" build \
    --output "$NEW_CADDY" \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/aUsernameWoW/forwardproxy@naive
}

build_zedifen() {
  log "Собираем Caddy с zedifen/forwardproxy@${ZEDIFEN_BRANCH}"

  rm -rf "$ZEDIFEN_DIR"
  git clone --depth 1 --branch "$ZEDIFEN_BRANCH" "$ZEDIFEN_REPO" "$ZEDIFEN_DIR"

  local caddy_version caddy_src
  caddy_version="$(tr -d '[:space:]' < "${ZEDIFEN_DIR}/CADDY_VERSION")"
  caddy_src="${ZEDIFEN_DIR}/.caddy-bbr"

  if [[ -z "$caddy_version" ]]; then
    err "Не удалось прочитать CADDY_VERSION из ${ZEDIFEN_DIR}"
    exit 1
  fi

  log "Версия Caddy для zedifen: $caddy_version"

  git clone --depth 1 --branch "$caddy_version" https://github.com/caddyserver/caddy.git "$caddy_src"

  log "Применяем патч caddy-sing-quic-bbrv1.patch"
  git -C "$caddy_src" apply "${ZEDIFEN_DIR}/caddy-sing-quic-bbrv1.patch"

  "$XCADDY" build "$caddy_version" \
    --output "$NEW_CADDY" \
    --replace "github.com/caddyserver/caddy/v2=${caddy_src}" \
    --with "github.com/caddyserver/forwardproxy=${ZEDIFEN_DIR}"
}

build_caddy() {
  rm -f "$NEW_CADDY"

  cd "$BUILD_DIR"

  case "$FORWARDPROXY" in
    awow) build_awow ;;
    zedifen) build_zedifen ;;
  esac

  if [[ ! -x "$NEW_CADDY" ]]; then
    err "Сборка завершилась, но бинарник не найден или не исполняемый: $NEW_CADDY"
    exit 1
  fi

  log "Новый Caddy собран: $NEW_CADDY (${GOOS}/${GOARCH})"

  log "Версия нового Caddy:"
  "$NEW_CADDY" version || true
}

ask_yes_no() {
  local prompt="$1" answer

  if ! { : </dev/tty; } 2>/dev/null; then
    return 0
  fi

  while true; do
    read -rp "$prompt [Y/n]: " answer </dev/tty
    case "${answer:-y}" in
      y|Y|yes|д|Д|да) return 0 ;;
      n|N|no|н|Н|нет) return 1 ;;
      *) warn "Введи y или n" ;;
    esac
  done
}

prepare_config() {
  if [[ "$FORWARDPROXY" != "zedifen" ]]; then
    return
  fi

  if ! grep -Eq "^[[:space:]]*(${ZEDIFEN_UNSUPPORTED_OPTIONS})([[:space:]]|$)" "$CADDY_CONFIG"; then
    return
  fi

  warn "В $CADDY_CONFIG есть опции, которых нет в zedifen/forwardproxy:"
  grep -En "^[[:space:]]*(${ZEDIFEN_UNSUPPORTED_OPTIONS})([[:space:]]|$)" "$CADDY_CONFIG" | sed 's/^/    /'
  echo ""
  echo "  В zedifen UDP включён всегда:"
  echo "    - CONNECT-UDP работает только по шаблону /.well-known/masque/udp/{host}/{port}/"
  echo "      (если udp_uri_template был другим, клиентам нужно перейти на этот путь)"
  echo "    - UoT-адреса всегда обрабатываются локально, passthrough_uot в upstream не поддерживается"
  echo ""

  if ! ask_yes_no "Закомментировать эти строки (оригинал сохранится в backup)?"; then
    err "Без правки конфига zedifen не запустится. Отредактируй $CADDY_CONFIG вручную и запусти скрипт снова"
    exit 1
  fi

  # Временный файл рядом с оригиналом, чтобы относительные import работали так же
  NEW_CONFIG="${CADDY_CONFIG}.new"
  sed -E "s/^([[:space:]]*)((${ZEDIFEN_UNSUPPORTED_OPTIONS})([[:space:]]|$))/\1# \2/" "$CADDY_CONFIG" > "$NEW_CONFIG"

  log "Подготовлен конфиг для zedifen: $NEW_CONFIG"
}

validate_new_caddy() {
  local config="${NEW_CONFIG:-$CADDY_CONFIG}"

  if [[ "$(env -u GOOS -u GOARCH -u GOARM go env GOARCH)" != "$GOARCH" || "$(uname -s | tr '[:upper:]' '[:lower:]')" != "$GOOS" ]]; then
    warn "Бинарник собран под другую платформу (${GOOS}/${GOARCH}), проверка конфига пропущена"
    return
  fi

  log "Проверяем конфиг новым бинарником: $config"

  if ! "$NEW_CADDY" validate --config "$config" --adapter "$CADDY_ADAPTER"; then
    err "Новый Caddy не принимает конфиг. Текущий сервис не тронут"
    [[ -n "$NEW_CONFIG" ]] && rm -f "$NEW_CONFIG"
    exit 1
  fi

  log "Конфиг валиден"
}

stop_current_caddy() {
  log "Останавливаем текущий сервис: $CADDY_SERVICE"

  systemctl stop "$CADDY_SERVICE"

  if systemctl is-active --quiet "$CADDY_SERVICE"; then
    err "Не удалось остановить $CADDY_SERVICE"
    exit 1
  fi

  log "$CADDY_SERVICE остановлен"
}

install_new_caddy() {
  log "Делаем backup старого бинарника"

  mv "$CADDY_BIN" "$OLD_BACKUP"
  log "Старый бинарник сохранён как: $OLD_BACKUP"

  log "Устанавливаем новый бинарник"

  mv "$NEW_CADDY" "$CADDY_BIN"

  chmod 755 "$CADDY_BIN"

  if command -v setcap >/dev/null 2>&1; then
    setcap 'cap_net_bind_service=+ep' "$CADDY_BIN" 2>/dev/null || warn "Не удалось установить setcap, сервис всё равно может работать через AmbientCapabilities"
  fi

  log "Новый бинарник установлен: $CADDY_BIN"
  "$CADDY_BIN" version || true

  if [[ -n "$NEW_CONFIG" ]]; then
    cp -p "$CADDY_CONFIG" "$CONFIG_BACKUP"
    log "Старый конфиг сохранён как: $CONFIG_BACKUP"
    cat "$NEW_CONFIG" > "$CADDY_CONFIG"
    rm -f "$NEW_CONFIG"
    log "Конфиг обновлён: $CADDY_CONFIG"
  fi
}

rollback() {
  warn "Откатываем изменения"

  systemctl stop "$CADDY_SERVICE" 2>/dev/null || true

  mv "$CADDY_BIN" "${CADDY_BIN}.failed"
  mv "$OLD_BACKUP" "$CADDY_BIN"
  log "Старый бинарник восстановлен, неудачный сохранён как: ${CADDY_BIN}.failed"

  if [[ -n "$NEW_CONFIG" && -f "$CONFIG_BACKUP" ]]; then
    cat "$CONFIG_BACKUP" > "$CADDY_CONFIG"
    log "Старый конфиг восстановлен из: $CONFIG_BACKUP"
  fi

  systemctl reset-failed "$CADDY_SERVICE" 2>/dev/null || true
  if systemctl start "$CADDY_SERVICE" && sleep 2 && systemctl is-active --quiet "$CADDY_SERVICE"; then
    log "$CADDY_SERVICE снова запущен со старым бинарником"
  else
    err "$CADDY_SERVICE не запустился и после отката, проверь: journalctl -u $CADDY_SERVICE -n 80 --no-pager"
  fi
}

start_caddy() {
  log "Запускаем сервис: $CADDY_SERVICE"

  systemctl reset-failed "$CADDY_SERVICE" 2>/dev/null || true
  # Не даём set -e оборвать скрипт до отката
  systemctl start "$CADDY_SERVICE" || true

  sleep 2

  if systemctl is-active --quiet "$CADDY_SERVICE"; then
    log "$CADDY_SERVICE запущен"
  else
    err "$CADDY_SERVICE не запустился"
    echo ""
    echo "Последние логи:"
    journalctl -u "$CADDY_SERVICE" -n 80 --no-pager -o cat || true
    echo ""
    rollback
    exit 1
  fi
}

verify() {
  log "Проверяем статус сервиса"

  systemctl status "$CADDY_SERVICE" --no-pager | sed -n '1,20p' || true

  echo ""
  log "Проверяем слушающие порты"

  ss -tlnp | grep -E ':80|:443|:8080|:3000' || true

  echo ""
  log "Проверяем версию установленного бинарника"

  "$CADDY_BIN" version || true

  echo ""
  log "Проверяем HTTP-ответы"

  if ss -tlnp | grep -q ':80'; then
    curl -I --max-time 8 http://127.0.0.1/ || true
  fi

  if ss -tlnp | grep -q ':8080'; then
    curl -I --max-time 8 http://127.0.0.1:8080/ || true
  fi

  echo ""
  log "Готово. Старый бинарник сохранён:"
  echo "  $OLD_BACKUP"

  if [[ -f "$CONFIG_BACKUP" ]]; then
    log "Старый конфиг сохранён:"
    echo "  $CONFIG_BACKUP"
  fi
}

main() {
  choose_forwardproxy "$@"
  need_root
  detect_platform
  check_requirements
  build_caddy
  prepare_config
  validate_new_caddy
  stop_current_caddy
  install_new_caddy
  start_caddy
  verify
}

main "$@"
