#!/bin/bash

# mtproxy-install.sh
# Установка MTProto Proxy с FakeTLS напрямую на порт 443

set -euo pipefail

# Цвета
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Логирование
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Проверка root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Запустите скрипт с sudo: sudo $0"
        exit 1
    fi
}

# Проверка зависимостей
check_deps() {
    local deps=("curl" "openssl" "xxd" "jq")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_step "Установка зависимостей: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}" || {
            log_error "Не удалось установить зависимости"
            exit 1
        }
    fi
}

# Проверка занятости порта
check_port() {
    local port=$1
    if ss -tlnp | grep -q ":$port "; then
        log_error "Порт $port уже занят:"
        ss -tlnp | grep ":$port "
        log_warn "Освободите порт или выберите другой"
        exit 1
    fi
}

# Валидация домена
validate_domain() {
    local domain=$1
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9](\.[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9])*$ ]]; then
        log_error "Некорректное доменное имя: $domain"
        return 1
    fi
    return 0
}

# Генерация секрета FakeTLS (ee-префикс)
generate_secret() {
    local domain=$1
    # 16 байт = 32 hex символа для ключа
    local secret_key=$(openssl rand -hex 16)
    # Домен в hex для маскировки
    local domain_hex=$(echo -n "$domain" | xxd -ps)
    echo "ee${secret_key}${domain_hex}"
}

# Установка Docker
install_docker() {
    log_step "Проверка Docker..."
    
    if command -v docker &> /dev/null; then
        log_info "Docker уже установлен: $(docker --version)"
        return 0
    fi
    
    log_step "Установка Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    
    # Проверка
    if ! docker run --rm hello-world &> /dev/null; then
        log_error "Docker не работает корректно"
        exit 1
    fi
    log_info "Docker установлен успешно"
}

# Получение параметров от пользователя
get_params() {
    echo ""
    log_step "Настройка параметров MTProto Proxy"
    echo "─────────────────────────────────────"
    
    # Домен для FakeTLS
    while true; do
        read -rp "Домен для FakeTLS [cloudflare.com]: " FAKE_DOMAIN
        FAKE_DOMAIN=${FAKE_DOMAIN:-cloudflare.com}
        validate_domain "$FAKE_DOMAIN" && break
        log_warn "Примеры правильных доменов: cloudflare.com, www.google.com, github.com"
    done
    
    # Порт
    while true; do
        read -rp "Порт [443]: " PORT
        PORT=${PORT:-443}
        [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) && break
        log_warn "Введите число от 1 до 65535"
    done
    
    check_port "$PORT"
    
    # Тег (опционально, для статистики)
    read -rp "Тег прокси (опционально, для @MTProxybot): " PROXY_TAG
    PROXY_TAG=${PROXY_TAG:-}
    
    # Секрет
    read -rp "Использовать свой секрет? [y/N]: " custom_secret
    if [[ "$custom_secret" =~ ^[Yy]$ ]]; then
        while true; do
            read -rp "Введите секрет (hex, 32 символа): " USER_SECRET
            [[ "$USER_SECRET" =~ ^[0-9a-fA-F]{32}$ ]] && break
            log_warn "Секрет должен быть 32 hex-символа (0-9, a-f)"
        done
        SECRET="ee${USER_SECRET}$(echo -n "$FAKE_DOMAIN" | xxd -ps)"
    else
        SECRET=$(generate_secret "$FAKE_DOMAIN")
    fi
    
    echo ""
    log_info "Параметры установки:"
    log_info "  Домен: $FAKE_DOMAIN"
    log_info "  Порт: $PORT"
    log_info "  Секрет: ${SECRET:0:16}...${SECRET: -8}"
    [[ -n "$PROXY_TAG" ]] && log_info "  Тег: $PROXY_TAG"
    
    read -rp "Продолжить установку? [Y/n]: " confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && exit 0
}

# Создание структуры директорий
setup_dirs() {
    WORK_DIR="/opt/mtproxy"
    log_step "Создание рабочей директории: $WORK_DIR"
    
    mkdir -p "$WORK_DIR"/{data,logs}
    cd "$WORK_DIR"
    
    # Очистка старых данных при необходимости
    if [[ -d "$WORK_DIR/data" ]] && [[ "$(ls -A "$WORK_DIR/data" 2>/dev/null)" ]]; then
        log_warn "Найдены старые данные"
        read -rp "Сохранить статистику и секрет? [Y/n]: " keep
        [[ "$keep" =~ ^[Nn]$ ]] && rm -rf "$WORK_DIR/data"/* "$WORK_DIR/logs"/*
    fi
}

# Создание Docker Compose конфигурации
create_compose() {
    log_step "Создание конфигурации Docker Compose..."
    
    cat > "$WORK_DIR/docker-compose.yml" << EOF
name: mtproxy

services:
  mtproxy:
    image: seriyps/mtproto-proxy:latest
    container_name: mtproto-proxy
    restart: unless-stopped
    
    ports:
      - "${PORT}:443/tcp"
    
    environment:
      - SECRET=${SECRET}
      - TAG=${PROXY_TAG}
      - WORKERS=16
      - VERBOSITY=0
    
    volumes:
      - ./data:/data
      - ./logs:/var/log/mtproto-proxy
    
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "443"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 512M
        reservations:
          cpus: '0.5'
          memory: 128M
    
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  default:
    name: mtproxy-network
    driver: bridge
EOF
}

# Создание скрипта управления
create_manager() {
    log_step "Создание скрипта управления..."
    
    cat > "$WORK_DIR/mtproxy-manager.sh" << 'EOF'
#!/bin/bash

WORK_DIR="/opt/mtproxy"
cd "$WORK_DIR" || exit 1

case "$1" in
    start)
        docker compose up -d
        ;;
    stop)
        docker compose down
        ;;
    restart)
        docker compose restart
        ;;
    logs)
        docker compose logs -f --tail=100
        ;;
    status)
        docker compose ps
        docker compose exec mtproxy wget -qO- http://localhost:2398/stats 2>/dev/null || echo "Статистика недоступна"
        ;;
    update)
        docker compose pull
        docker compose up -d
        ;;
    backup)
        tar -czf "backup-$(date +%Y%m%d-%H%M%S).tar.gz" data/
        echo "Бэкап создан"
        ;;
    *)
        echo "Использование: $0 {start|stop|restart|logs|status|update|backup}"
        exit 1
        ;;
esac
EOF
    
    chmod +x "$WORK_DIR/mtproxy-manager.sh"
    ln -sf "$WORK_DIR/mtproxy-manager.sh" /usr/local/bin/mtproxy
}

# Запуск сервиса
start_service() {
    log_step "Запуск MTProto Proxy..."
    
    cd "$WORK_DIR"
    docker compose down 2>/dev/null || true
    docker compose up -d
    
    # Ожидание запуска
    local retries=0
    while [[ $retries -lt 10 ]]; do
        if docker compose ps | grep -q "healthy\|Up"; then
            sleep 2
            log_info "Сервис запущен успешно"
            return 0
        fi
        sleep 1
        ((retries++))
    done
    
    log_error "Сервис не запустился. Проверьте логи: docker compose logs"
    exit 1
}

# Получение внешнего IP
get_ip() {
    local ip=""
    local services=("ifconfig.me" "icanhazip.com" "ipinfo.io/ip" "api.ipify.org")
    
    for service in "${services[@]}"; do
        ip=$(curl -s --max-time 3 "https://$service" 2>/dev/null || curl -s --max-time 3 "http://$service" 2>/dev/null)
        [[ -n "$ip" ]] && break
    done
    
    echo "$ip"
}

# Сохранение информации
save_info() {
    local ip=$1
    local info_file="$WORK_DIR/proxy-info.txt"
    local qr_file="$WORK_DIR/proxy-qr.txt"
    
    # Ссылка подключения
    local link="tg://proxy?server=${ip}&port=${PORT}&secret=${SECRET}"
    
    # JSON для бота
    local json_info=$(jq -n \
        --arg server "$ip" \
        --arg port "$PORT" \
        --arg secret "$SECRET" \
        --arg domain "$FAKE_DOMAIN" \
        '{server: $server, port: ($port|tonumber), secret: $secret, domain: $domain}')
    
    cat > "$info_file" << EOF
MTProto Proxy Configuration
============================
Дата установки: $(date '+%Y-%m-%d %H:%M:%S')
IP сервера: $ip
Порт: $PORT
Секрет: $SECRET
FakeTLS домен: $FAKE_DOMAIN
Тег: ${PROXY_TAG:-не указан}

Ссылки для подключения:
-----------------------
1. tg:// ссылка:
${link}

2. HTTPS ссылка (для sharing):
https://t.me/proxy?server=${ip}&port=${PORT}&secret=${SECRET}

JSON конфигурация:
${json_info}

Управление:
-----------
cd ${WORK_DIR}
docker compose logs -f     # Логи
docker compose restart     # Перезапуск
mtproxy status             # Статус
mtproxy update             # Обновление

Файлы:
------
Конфигурация: ${WORK_DIR}/docker-compose.yml
Данные: ${WORK_DIR}/data/
Логи: ${WORK_DIR}/logs/
EOF
    
    # Генерация QR кода (если установлен qrencode)
    if command -v qrencode &> /dev/null; then
        echo "$link" | qrencode -t ANSIUTF8 > "$qr_file"
        echo "" >> "$info_file"
        echo "QR код:" >> "$info_file"
        cat "$qr_file" >> "$info_file"
    fi
    
    chmod 600 "$info_file"
}

# Вывод финальной информации
show_final() {
    local ip=$1
    local link="tg://proxy?server=${ip}&port=${PORT}&secret=${SECRET}"
    
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           ${GREEN}✅ MTProto Proxy УСПЕШНО УСТАНОВЛЕН${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}📱 Быстрое подключение:${NC}"
    echo -e "${GREEN}${link}${NC}"
    echo ""
    echo -e "${YELLOW}🔑 Параметры:${NC}"
    echo -e "   Сервер: ${CYAN}${ip}${NC}"
    echo -e "   Порт:   ${CYAN}${PORT}${NC}"
    echo -e "   Секрет: ${CYAN}${SECRET}${NC}"
    echo -e "   Домен:  ${CYAN}${FAKE_DOMAIN}${NC}"
    [[ -n "$PROXY_TAG" ]] && echo -e "   Тег:    ${CYAN}${PROXY_TAG}${NC}"
    echo ""
    echo -e "${YELLOW}🛠 Управление:${NC}"
    echo -e "   ${CYAN}mtproxy status${NC}  - статус и статистика"
    echo -e "   ${CYAN}mtproxy logs${NC}    - просмотр логов"
    echo -e "   ${CYAN}mtproxy restart${NC} - перезапуск"
    echo -e "   ${CYAN}mtproxy update${NC}  - обновление"
    echo ""
    echo -e "${YELLOW}📁 Файлы:${NC}"
    echo -e "   Конфиг: ${WORK_DIR}/docker-compose.yml"
    echo -e "   Инфо:   ${WORK_DIR}/proxy-info.txt"
    echo ""
    echo -e "${GREEN}Для добавления в Telegram скопируйте ссылку выше${NC}"
}

# Настройка фаервола
setup_firewall() {
    log_step "Настройка фаервола..."
    
    if command -v ufw &> /dev/null; then
        ufw allow "$PORT/tcp" comment "MTProto Proxy" 2>/dev/null || true
        log_info "Порт $PORT открыт в UFW"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port="$PORT/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log_info "Порт $PORT открыт в firewalld"
    else
        log_warn "Не удалось настроить фаервол автоматически"
        log_warn "Откройте порт $PORT/tcp вручную"
    fi
}

# Очистка при ошибке
cleanup() {
    if [[ $? -ne 0 ]]; then
        log_error "Установка прервана с ошибкой"
        log_info "Для очистки выполните: rm -rf $WORK_DIR"
    fi
}
trap cleanup EXIT

# Главная функция
main() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════╗"
    echo "║     MTProto Proxy Installer            ║"
    echo "║     with FakeTLS support               ║"
    echo "╚════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_root
    check_deps
    install_docker
    get_params
    setup_dirs
    create_compose
    create_manager
    setup_firewall
    start_service
    
    IP=$(get_ip)
    if [[ -z "$IP" ]]; then
        log_warn "Не удалось определить внешний IP"
        IP="YOUR_SERVER_IP"
    fi
    
    save_info "$IP"
    show_final "$IP"
}

main "$@"
