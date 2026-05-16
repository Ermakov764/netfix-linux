#!/bin/bash

set -euo pipefail

INTERNET_CHECK_RETRIES=3
INTERNET_CHECK_DELAY=4
CAPTIVE_PORTAL_SUSPECT=0
STAGE1_INTERNET_OK=1

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Логирование
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="/var/log/network-reset-${TIMESTAMP}.log"
BACKUP_DIR="/var/backups/network-${TIMESTAMP}"

# ============================================================================
# Функции логирования
# ============================================================================

log() { echo -e "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
log_error() { log "${RED}❌ $1${NC}"; }
log_warn()  { log "${YELLOW}⚠️  $1${NC}"; }
log_info()  { log "${BLUE}ℹ️  $1${NC}"; }
log_success() { log "${GREEN}✅ $1${NC}"; }
log_stage1() { log "${CYAN}🔹 ЭТАП 1: $1${NC}"; }
log_stage2() { log "${MAGENTA}☢️  ЭТАП 2: $1${NC}"; }

# ============================================================================
# Проверки
# ============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Требуется root (sudo)"
        exit 1
    fi
}

check_ssh_sessions() {
    local ssh_count
    ssh_count=$(who 2>/dev/null | grep -c pts || echo 0)
    if [ "$ssh_count" -gt 0 ]; then
        log_warn "Обнаружено SSH-сессий: $ssh_count"
        who | grep pts || true
    fi
}

backup_rules() {
    log_info "Создание резервной копии..."
    mkdir -p "$BACKUP_DIR"
    iptables-save > "$BACKUP_DIR/iptables.txt" 2>/dev/null || true
    ip link show > "$BACKUP_DIR/links.txt" 2>/dev/null || true
    ip route show > "$BACKUP_DIR/routes.txt" 2>/dev/null || true
    conntrack -L > "$BACKUP_DIR/conntrack.txt" 2>/dev/null || true
    log_success "Бэкап: $BACKUP_DIR"
    echo "$BACKUP_DIR" > /var/backups/network-latest.txt 2>/dev/null || true
}

get_latest_backup_dir() {
    if [ -f /var/backups/network-latest.txt ]; then
        local saved
        saved=$(cat /var/backups/network-latest.txt 2>/dev/null)
        if [ -n "$saved" ] && [ -d "$saved" ]; then
            echo "$saved"
            return 0
        fi
    fi
    ls -td /var/backups/network-[0-9]* 2>/dev/null | head -1
}

# Вывод команд отката (после этапа 1 и 2)
print_restore_backup_hint() {
    local stage_label="${1:-}"
    local latest
    latest=$(get_latest_backup_dir || true)

    echo ""
    echo -e "${YELLOW}─────────────────────────────────────────────────────────${NC}"
    if [ -n "$stage_label" ]; then
        log_info "Вернуть последний бэкап (после ${stage_label}):"
    else
        log_info "Вернуть последний бэкап:"
    fi
    echo ""
    echo "   Каталог бэкапа этой сессии:"
    echo "   $BACKUP_DIR"
    echo ""
    if [ -n "$latest" ] && [ "$latest" != "$BACKUP_DIR" ]; then
        echo "   Последний бэкап в /var/backups:"
        echo "   $latest"
        echo ""
    fi

    local restore_dir="${latest:-$BACKUP_DIR}"
    if [ ! -d "$restore_dir" ]; then
        restore_dir="$BACKUP_DIR"
    fi

    echo "   Восстановить правила iptables:"
    echo "   sudo iptables-restore < \"$restore_dir/iptables.txt\""
    echo ""
    echo "   (бэкап этой сессии — та же команда с вашим каталогом:)"
    echo "   sudo iptables-restore < \"$BACKUP_DIR/iptables.txt\""
    echo ""
    echo "   Справочно (просмотр, не автоматический откат):"
    echo "   less \"$restore_dir/routes.txt\""
    echo "   less \"$restore_dir/links.txt\""
    echo -e "${YELLOW}─────────────────────────────────────────────────────────${NC}"
}

# ============================================================================
# Проверка интернета
# Провал HTTP/HTTPS при успешном ping/DNS/IPv6 не валит этап 1.
# neverssl: успех только если в теле ответа есть «NeverSSL».
# ============================================================================

http_check_curl() {
    local url="$1"
    local extra=()
    [ "${2:-}" = "-6" ] && extra=(-6)
    curl "${extra[@]}" -fsS --connect-timeout 5 --max-time 10 "$url" &>/dev/null
}

check_neverssl_body() {
    CAPTIVE_PORTAL_SUSPECT=0
    local body
    body=$(curl -fsS --connect-timeout 5 --max-time 10 http://neverssl.com/ 2>/dev/null) || return 1
    if echo "$body" | grep -qi 'NeverSSL'; then
        return 0
    fi
    CAPTIVE_PORTAL_SUSPECT=1
    return 1
}

check_internet_once() {
    echo ""
    log_info "Проверка подключения к интернету..."

    local core_ok=0 http_ok=0 http_ran=0
    local neverssl_ok=0 https_ok=0 ipv6_ok=0
    local step=1 total=7

    echo -n "   [$step/$total] Ping 8.8.8.8... "
    step=$((step + 1))
    if ping -c 2 -W 3 8.8.8.8 &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        core_ok=1
    else
        echo -e "${RED}FAIL${NC}"
    fi

    echo -n "   [$step/$total] Ping 1.1.1.1... "
    step=$((step + 1))
    if ping -c 2 -W 3 1.1.1.1 &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        core_ok=1
    else
        echo -e "${RED}FAIL${NC}"
    fi

    echo -n "   [$step/$total] DNS google.com... "
    step=$((step + 1))
    if getent hosts google.com &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        core_ok=1
    else
        echo -e "${RED}FAIL${NC}"
    fi

    echo -n "   [$step/$total] Ping6 2001:4860:4860::8888... "
    step=$((step + 1))
    if ping -6 -c 2 -W 3 2001:4860:4860::8888 &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        ipv6_ok=1
        core_ok=1
    else
        echo -e "${RED}FAIL${NC}"
    fi

    if command -v curl &>/dev/null; then
        http_ran=1

        echo -n "   [$step/$total] HTTP neverssl (тело)... "
        step=$((step + 1))
        if check_neverssl_body; then
            echo -e "${GREEN}OK${NC}"
            neverssl_ok=1
            http_ok=1
        else
            if [ "$CAPTIVE_PORTAL_SUSPECT" -eq 1 ]; then
                echo -e "${YELLOW}PORTAL?${NC}"
            else
                echo -e "${RED}FAIL${NC}"
            fi
        fi

        echo -n "   [$step/$total] HTTPS example.com... "
        step=$((step + 1))
        if http_check_curl "https://example.com"; then
            echo -e "${GREEN}OK${NC}"
            https_ok=1
            http_ok=1
        else
            echo -e "${RED}FAIL${NC}"
        fi

        echo -n "   [$step/$total] HTTPS6 example.com... "
        if http_check_curl "https://example.com" "-6"; then
            echo -e "${GREEN}OK${NC}"
            ipv6_ok=1
            http_ok=1
        else
            echo -e "${RED}FAIL${NC}"
        fi
    else
        echo -e "   [$step/$total] HTTP/HTTPS... ${YELLOW}SKIP (нет curl)${NC}"
    fi

    echo ""

    if [ "$CAPTIVE_PORTAL_SUSPECT" -eq 1 ]; then
        log_warn "Captive portal: HTTP отвечает, но это не страница NeverSSL."
        log_info "Откройте в браузере: http://neverssl.com/ и пройдите авторизацию Wi‑Fi."
    fi

    if [ "$http_ok" -eq 1 ]; then
        if [ "$neverssl_ok" -eq 1 ] && [ "$https_ok" -eq 0 ]; then
            log_success "Интернет: neverssl OK; HTTPS не отвечает"
        elif [ "$neverssl_ok" -eq 0 ] && [ "$https_ok" -eq 1 ]; then
            log_success "Интернет: HTTPS доступен"
        else
            log_success "Интернет: HTTP/HTTPS доступны"
        fi
        [ "$ipv6_ok" -eq 1 ] && log_info "IPv6: проверка пройдена" || log_info "IPv6: не подтверждён (IPv4 может работать)"
        return 0
    fi

    if [ "$core_ok" -eq 1 ]; then
        if [ "$http_ran" -eq 1 ]; then
            log_warn "Ping/DNS/IPv6 в порядке, HTTP/HTTPS не прошли — этап 1 считается успешным."
        else
            log_success "Интернет: доступен (ping/DNS/IPv6, HTTP не проверялся)"
        fi
        [ "$ipv6_ok" -eq 1 ] && log_info "IPv6: OK" || true
        return 0
    fi

    if [ "$http_ran" -eq 0 ]; then
        log_error "Интернет: недоступен (установите curl для HTTP-проверки)"
    else
        log_error "Интернет: недоступен"
    fi
    return 1
}

check_internet() {
    check_internet_once
}

check_internet_with_retries() {
    local attempt result=1
    for ((attempt = 1; attempt <= INTERNET_CHECK_RETRIES; attempt++)); do
        if [ "$attempt" -gt 1 ]; then
            log_info "Повтор проверки ($attempt/$INTERNET_CHECK_RETRIES) через ${INTERNET_CHECK_DELAY} с..."
            sleep "$INTERNET_CHECK_DELAY"
        fi
        check_internet_once
        result=$?
        if [ "$result" -eq 0 ]; then
            [ "$attempt" -gt 1 ] && log_success "Интернет доступен с попытки $attempt"
            return 0
        fi
    done
    log_warn "Интернет недоступен после $INTERNET_CHECK_RETRIES попыток"
    return 1
}

# ============================================================================
# Диагностика без изменений системы
# ============================================================================

print_network_diagnostics() {
    echo ""
    log_info "=== ДИАГНОСТИКА СЕТИ (без изменений) ==="
    echo ""
    echo "   Интерфейсы:"
    ip -br link show | head -12 || true
    echo ""
    if command -v nmcli &>/dev/null; then
        echo "   NetworkManager:"
        nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null | head -12 || true
        echo ""
    fi
    echo "   Маршрут по умолчанию:"
    ip route show default 2>/dev/null || echo "   (нет default route)"
    ip -6 route show default 2>/dev/null || true
    echo ""
    echo "   DNS:"
    resolvectl status 2>/dev/null | head -20 || grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || true
    echo ""
    (systemctl is-active ufw 2>/dev/null && echo "   UFW: активен") || \
    (systemctl is-active firewalld 2>/dev/null && echo "   Firewalld: активен") || \
    echo "   Фаервол: не активен"
    echo ""
}

run_diagnostics_only() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              РЕЖИМ: ТОЛЬКО ДИАГНОСТИКА                ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    print_network_diagnostics
    set +e
    check_internet_with_retries
    set -e
    echo ""
    log_info "Система не изменялась. Лог: $LOG_FILE"
}

# ============================================================================
# Baseline до этапа 1
# ============================================================================

baseline_before_stage1() {
    echo ""
    log_info "=== ПРОВЕРКА ДО СБРОСА (baseline) ==="
    set +e
    check_internet_with_retries
    local baseline_ok=$?
    set -e

    if [ "$baseline_ok" -ne 0 ]; then
        log_info "Интернет до сброса недоступен — запуск ЭТАПА 1 уместен."
        return 0
    fi

    echo ""
    log_success "Интернет уже доступен."
    log_warn "Жёсткий сброс остановит Docker/K8s и сбросит iptables."
    echo ""
    log_info "Выберите действие:"
    echo "   [1] Только диагностика (без изменений системы)"
    echo "   [2] Всё равно запустить ЭТАП 1 (сброс)"
    echo "   [3] Выход"
    echo ""

    local choice
    read -r -p "Ваш выбор [1/2/3] (по умолчанию 3): " choice
    choice="${choice:-3}"

    case "$choice" in
        1)
            run_diagnostics_only
            exit 0
            ;;
        2)
            log_warn "Продолжаем ЭТАП 1 несмотря на рабочий интернет."
            read -r -p "Подтвердите (y/n): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log_info "Отменено."
                exit 0
            fi
            return 0
            ;;
        *)
            log_info "Выход без изменений."
            exit 0
            ;;
    esac
}

# ============================================================================
# Удаление залипших мостов Docker/K8s
# ============================================================================

remove_stale_bridge() {
    local iface="$1"
    if ! ip link show "$iface" &>/dev/null; then
        return 0
    fi
    ip link set "$iface" down 2>/dev/null || true
    if ip link delete "$iface" 2>/dev/null; then
        log_info "Удалён интерфейс: $iface"
        return 0
    fi
    log_warn "Не удалось удалить $iface (возможно занят)"
    return 1
}

cleanup_container_bridges() {
    local iface
    for iface in docker0 cni0 flannel.1 calico weave virbr0 mpqemubr0; do
        remove_stale_bridge "$iface"
    done
}

# ============================================================================
# Предупреждения перед этапом 2
# context: recommended — сеть не работает; optional — сеть уже работает
# ============================================================================

print_stage2_warnings() {
    local context="${1:-recommended}"

    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║         ПРЕДУПРЕЖДЕНИЯ: ЭТАП 2 (ЯДЕРНЫЙ)              ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    case "$context" in
        optional)
            log_warn "Интернет после ЭТАПА 1 уже доступен."
            log_warn "Ядерная очистка может РАЗОРВАТЬ рабочее соединение и ухудшить ситуацию."
            log_warn "Используйте только при «залипших» Docker/K8s, маршрутах или conntrack."
            ;;
        recommended)
            log_warn "Интернет после ЭТАПА 1 недоступен."
            log_warn "Этап 2 — агрессивная мера перед reboot и ручной диагностикой."
            ;;
    esac

    echo ""
    log_stage2 "Будет выполнено дополнительно:"
    echo "   • Полная очистка таблицы conntrack"
    echo "   • Удаление veth/lxc/nic интерфейсов"
    echo "   • Сброс ARP-кэша"
    echo "   • Сброс кэша маршрутов"
    echo "   • Удаление записей в /var/run/netns/"
    echo "   • Снятие блокировки /run/xtables.lock"
    echo "   • Повторный перезапуск NetworkManager"
    echo ""

    log_error "Критические последствия:"
    echo "   • Все активные TCP/UDP-сессии будут сброшены"
    echo "   • SSH-сессия, скорее всего, оборвётся"
    echo "   • VPN (WireGuard/OpenVPN) может отключиться"
    echo "   • Контейнеры без запущенного Docker останутся «осиротевшими» по сети"
    echo "   • Нужна консоль хостинга (VNC/IPMI) или физический доступ"
    echo ""

    log_warn "Перед запуском убедитесь:"
    echo "   • Есть доступ к консоли провайдера, если это удалённый сервер"
    echo "   • Сохранён бэкап: $BACKUP_DIR"
    echo "   • Вы понимаете, что откат — reboot или iptables-restore из бэкапа"
    echo ""

    check_ssh_sessions
    echo ""
}

confirm_stage2() {
    local context="${1:-recommended}"

    print_stage2_warnings "$context"

    echo -e "${RED}Для подтверждения введите YES заглавными буквами.${NC}"
    read -r -p "Подтвердить запуск ЭТАПА 2? (YES / anything else): " confirm
    if [[ "$confirm" != "YES" ]]; then
        log_info "ЭТАП 2 отменён (подтверждение не получено)."
        return 1
    fi
    return 0
}

# ============================================================================
# Меню после этапа 1
# Возврат: 0 — этап 2; 1 — выход
# STAGE1_INTERNET_OK обновляется при пункте [3]
# ============================================================================

show_stage1_menu_status() {
    if [ "$STAGE1_INTERNET_OK" -eq 0 ]; then
        echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
        log_success "Сеть после ЭТАПА 1: РАБОТАЕТ"
        echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
        OFFER_STAGE2_CONTEXT="optional"
        echo ""
        log_info "Обычно на этом этапе скрипт можно завершить."
        log_warn "ЭТАП 2 вручную — только при проблемах Docker/K8s или маршрутах."
    else
        echo -e "${RED}════════════════════════════════════════════════════════${NC}"
        log_error "Сеть после ЭТАПА 1: НЕ РАБОТАЕТ"
        echo -e "${RED}════════════════════════════════════════════════════════${NC}"
        OFFER_STAGE2_CONTEXT="recommended"
        echo ""
        log_warn "Попробуйте [3] повторить проверку или [2] — ядерный этап."
    fi
}

offer_stage2_after_stage1() {
    while true; do
        echo ""
        echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║              ЗАВЕРШЕНИЕ ЭТАПА 1 — МЕНЮ                ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""

        show_stage1_menu_status

        echo ""
        log_info "Доступные действия:"
        echo "   [1] Завершить (без ядерной очистки)"
        echo "   [2] Вручную запустить ЭТАП 2 — ядерная очистка"
        echo "   [3] Повторить проверку интернета (без повторного сброса)"
        echo ""
        log_warn "Пункт [2] покажет предупреждения и запросит YES."
        echo ""

        local choice
        read -r -p "Ваш выбор [1/2/3] (по умолчанию 1): " choice
        choice="${choice:-1}"

        case "$choice" in
            2)
                log_info "Выбран ручной запуск ЭТАПА 2."
                return 0
                ;;
            3)
                log_info "Повторная проверка интернета..."
                set +e
                check_internet_with_retries
                STAGE1_INTERNET_OK=$?
                set -e
                continue
                ;;
            *)
                log_info "ЭТАП 2 не запускается. Завершение."
                return 1
                ;;
        esac
    done
}

# ============================================================================
# ЭТАП 1: Жёсткий сброс
# ============================================================================

stage1_hard_reset() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           ЭТАП 1: ЖЁСТКИЙ СБРОС СЕТИ                   ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    log_stage1 "Что будет сделано:"
    echo "   • Остановка Docker, Kubernetes, контейнеров"
    echo "   • Сброс правил iptables"
    echo "   • Удаление залипших мостов (docker0, cni0, и т.д.)"
    echo "   • Перезапуск NetworkManager"
    echo "   • Очистка DNS кэша"
    echo ""
    log_warn "Сервисы НЕ будут перезапущены автоматически!"
    log_info "После этапа 1 в меню можно вручную запустить ЭТАП 2 (с предупреждениями)."
    echo ""

    read -r -p "Продолжить ЭТАП 1? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Отменено пользователем."
        exit 0
    fi

    backup_rules
    echo ""

    log_stage1 "=== ЗАПУСК ЭТАПА 1 ==="
    sleep 2

    log_stage1 "Остановка сервисов..."
    SERVICES=("kubelet" "k3s" "docker" "containerd" "crio" "podman")
    for svc in "${SERVICES[@]}"; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        pkill -9 -f "$svc" 2>/dev/null || true
    done
    log_success "Сервисы остановлены"

    log_stage1 "Удаление залипших мостов Docker/K8s..."
    cleanup_container_bridges
    log_success "Мосты обработаны (down + delete)"

    log_stage1 "Сброс iptables..."
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    log_success "iptables сброшен"

    if command -v ipvsadm &>/dev/null; then
        log_stage1 "Очистка IPVS..."
        ipvsadm -C 2>/dev/null || true
        log_success "IPVS очищен"
    fi

    log_stage1 "Перезапуск NetworkManager..."
    systemctl restart NetworkManager
    sleep 5
    log_success "NetworkManager перезапущен"

    log_stage1 "Очистка DNS кэша..."
    resolvectl flush-caches 2>/dev/null || true
    log_success "DNS кэш очищен"

    echo ""
    log_stage1 "=== ПРОВЕРКА ПОСЛЕ ЭТАПА 1 ==="
    check_internet_with_retries
    local result=$?

    echo ""
    echo -e "${CYAN}─────────────────────────────────────────────────────────${NC}"
    log_info "Статус после ЭТАПА 1:"
    echo "   Активные интерфейсы:"
    ip -br link show | grep -v "DOWN" | head -8 || true
    echo ""
    echo "   Статус фаервола:"
    (systemctl is-active ufw 2>/dev/null && echo "   UFW: активен") || \
    (systemctl is-active firewalld 2>/dev/null && echo "   Firewalld: активен") || \
    echo "   Фаервол: не активен"
    echo ""
    echo "   Остановленные сервисы:"
    for svc in "${SERVICES[@]}"; do
        systemctl is-active --quiet "$svc" 2>/dev/null && echo "   - $svc: работает" || echo "   - $svc: остановлен"
    done
    echo -e "${CYAN}─────────────────────────────────────────────────────────${NC}"
    print_restore_backup_hint "ЭТАПА 1"

    return $result
}

# ============================================================================
# ЭТАП 2: выполнение (подтверждение — в confirm_stage2)
# ============================================================================

stage2_nuclear_execute() {
    clear
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║      ЭТАП 2: ЯДЕРНАЯ ОЧИСТКА (MAXIMUM CLEANUP)         ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    log_stage2 "=== ЗАПУСК ЭТАПА 2 ==="
    sleep 3

    log_stage2 "Очистка conntrack таблицы..."
    if command -v conntrack &>/dev/null; then
        conntrack -F 2>/dev/null && log_success "Conntrack очищен" || log_warn "Не удалось очистить conntrack"
    else
        log_warn "Утилита conntrack не найдена"
    fi

    log_stage2 "Удаление veth интерфейсов..."
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^veth|^lxc|^nic' 2>/dev/null || true); do
        ip link delete "$iface" 2>/dev/null && log_info "Удалён: $iface" || true
    done
    log_success "veth интерфейсы зачищены"

    log_stage2 "Сброс ARP кэша..."
    ip neigh flush all 2>/dev/null || true
    log_success "ARP кэш очищен"

    log_stage2 "Сброс маршрутов..."
    ip route flush table cache 2>/dev/null || true
    ip link set lo up 2>/dev/null || true
    log_success "Маршруты сброшены"

    log_stage2 "Очистка сетевых неймспейсов..."
    for ns in /var/run/netns/*; do
        [ -e "$ns" ] && rm -f "$ns" && log_info "Удалён неймспейс: $(basename "$ns")" || true
    done 2>/dev/null || true
    log_success "Неймспейсы очищены"

    log_stage2 "Снятие блокировок xtables..."
    rm -f /run/xtables.lock 2>/dev/null || true
    log_success "Блокировки сняты"

    log_stage2 "Перезапуск NetworkManager..."
    systemctl restart NetworkManager
    sleep 5
    log_success "NetworkManager перезапущен"

    echo ""
    log_stage2 "=== ПРОВЕРКА ПОСЛЕ ЭТАПА 2 ==="
    check_internet_with_retries
    local result=$?

    echo ""
    echo -e "${MAGENTA}─────────────────────────────────────────────────────────${NC}"
    log_info "Статус после ЭТАПА 2:"
    echo "   Активные интерфейсы:"
    ip -br link show | grep -v "DOWN" | head -8 || true
    echo ""
    echo "   Conntrack записей:"
    conntrack -L 2>/dev/null | wc -l || echo "   0"
    echo ""
    echo "   iptables правил:"
    iptables -L -n 2>/dev/null | wc -l || echo "   0"
    echo -e "${MAGENTA}─────────────────────────────────────────────────────────${NC}"
    print_restore_backup_hint "ЭТАПА 2"

    return $result
}

stage2_nuclear_reset() {
    local context="${1:-recommended}"

    if ! confirm_stage2 "$context"; then
        return 2
    fi

    stage2_nuclear_execute
}

# ============================================================================
# Главная программа
# ============================================================================

main() {
    clear
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Network Reset - Two-Stage Diagnostic Tool          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_root
    check_ssh_sessions

    log_info "Лог файл: $LOG_FILE"
    log_info "Бэкап: $BACKUP_DIR"
    echo ""

    baseline_before_stage1

    set +e
    stage1_hard_reset
    STAGE1_INTERNET_OK=$?
    set -e

    OFFER_STAGE2_CONTEXT="recommended"
    set +e
    if offer_stage2_after_stage1; then
        local context="${OFFER_STAGE2_CONTEXT:-recommended}"
        stage2_nuclear_reset "$context"
        local stage2_run=$?
        set -e

        if [ "$stage2_run" -eq 2 ]; then
            log_warn "Этап 2 отменён на этапе подтверждения."
            if [ "$STAGE1_INTERNET_OK" -eq 0 ]; then
                log_info "Сеть после этапа 1 работала — можно завершать."
                exit 0
            fi
            log_warn "Сеть может оставаться нестабильной."
            exit 1
        fi

        local stage2_result=$stage2_run
        echo ""
        if [ "$stage2_result" -eq 0 ]; then
            echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
            log_success "Сеть работает после ЭТАПА 2"
            echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
        else
            echo -e "${RED}════════════════════════════════════════════════════════${NC}"
            log_error "Сеть всё ещё не работает после ЭТАПА 2"
            echo -e "${RED}════════════════════════════════════════════════════════${NC}"
            echo ""
            log_warn "Возможные причины:"
            echo "   • Нет линка Wi‑Fi/Ethernet (проверьте nmcli device status)"
            echo "   • Ошибка в netplan / NetworkManager"
            echo "   • Проблема у провайдера"
            echo "   • Нужна перезагрузка: sudo reboot"
            echo ""
            log_info "Диагностика:"
            echo "   journalctl -u NetworkManager -n 50"
            print_restore_backup_hint
        fi
    else
        set -e
        if [ "$STAGE1_INTERNET_OK" -eq 0 ]; then
            echo ""
            log_info "Включите сервисы при необходимости:"
            echo "   sudo systemctl enable --now docker"
            echo "   sudo systemctl enable --now kubelet"
            exit 0
        fi
        log_warn "Сеть не восстановлена. Этап 2 не запускался."
        log_info "Запустите скрипт снова и выберите пункт [2], или проверьте NM/reboot."
        exit 1
    fi

    echo ""
    log_info "Лог: $LOG_FILE"
    log_info "Бэкап: $BACKUP_DIR"
}

main
