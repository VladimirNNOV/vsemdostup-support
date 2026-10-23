#!/bin/bash
# ---------------------------------------------------------------------------
# Диагностика сети на macOS для поддержки VsemDOSTUP.
#
# Что делает: только ЧИТАЕТ настройки и делает 2 сетевых запроса.
# Ничего не меняет, ничего не устанавливает, файлов не создаёт, секретов не печатает.
#
# Как запустить:
#   1) скачать файл,
#   2) если двойной клик не открывает — Терминал: bash ~/Downloads/collect_macos_diag.command
#   3) скопировать весь текст окна (Cmd+A, Cmd+C) или сделать скриншот
# ---------------------------------------------------------------------------

set -u

LIMIT=12   # сколько строк показывать в каждом разделе

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n===== %s =====\n' "$*"; }
line() { printf '  %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(uname -s)" != "Darwin" ]; then
    say "Этот скрипт работает только на macOS (Apple). Текущая система: $(uname -s)."
    exit 1
fi

say "VsemDOSTUP — диагностика Mac"
say "Дата и время: $(date '+%d.%m.%Y %H:%M:%S %Z')"

# --- 1. Система -------------------------------------------------------------
hdr "1. Система"
line "macOS: $(sw_vers -productVersion 2>/dev/null) (сборка $(sw_vers -buildVersion 2>/dev/null))"
line "Архитектура: $(uname -m)"

# --- 2. Сетевые сервисы и прокси -------------------------------------------
hdr "2. Системный прокси"
PROXY_STATE="не включён"
if have networksetup; then
    while IFS= read -r svc; do
        case "$svc" in
            ''|'*'*|disabled*) continue ;;
        esac
        web=$(networksetup -getwebproxy "$svc" 2>/dev/null | awk -F': ' '/^Enabled/{print $2}')
        sec=$(networksetup -getsecurewebproxy "$svc" 2>/dev/null | awk -F': ' '/^Enabled/{print $2}')
        soc=$(networksetup -getsocksfirewallproxy "$svc" 2>/dev/null | awk -F': ' '/^Enabled/{print $2}')
        [ "$web" = "Yes" ] && PROXY_STATE="HTTP-прокси включён ($svc)" && line "$svc: HTTP-прокси включён -> $(networksetup -getwebproxy "$svc" | awk -F': ' '/^Server|^Port/{printf "%s ", $2}')"
        [ "$sec" = "Yes" ] && PROXY_STATE="HTTPS-прокси включён ($svc)" && line "$svc: HTTPS-прокси включён -> $(networksetup -getsecurewebproxy "$svc" | awk -F': ' '/^Server|^Port/{printf "%s ", $2}')"
        [ "$soc" = "Yes" ] && PROXY_STATE="SOCKS-прокси включён ($svc)" && line "$svc: SOCKS-прокси включён -> $(networksetup -getsocksfirewallproxy "$svc" | awk -F': ' '/^Server|^Port/{printf "%s ", $2}')"
    done <<< "$(networksetup -listallnetworkservices 2>/dev/null)"
fi
line "Итог по прокси: $PROXY_STATE"

# --- 3. Маршрут по умолчанию и туннель -------------------------------------
hdr "3. Маршрут по умолчанию (перехватывает ли VPN весь трафик)"
ROUTE_IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
line "Маршрут по умолчанию идёт через: ${ROUTE_IF:-не определён}"
case "$ROUTE_IF" in
    utun*) line "Это туннель (utun): весь трафик системы идёт через VPN." ;;
    en*|bridge*) line "Это обычный интерфейс: трафик идёт напрямую, VPN может стоять в режиме прокси." ;;
esac
if have ifconfig; then
    line "Активные туннели utun: $(ifconfig 2>/dev/null | grep -c '^utun[0-9]*:')"
    ifconfig 2>/dev/null | grep -E '^(utun[0-9]+|en[0-9]+):' | head -"$LIMIT" | while IFS= read -r l; do line "$l"; done
fi

# --- 4. DNS ----------------------------------------------------------------
hdr "4. DNS-серверы и адрес chatgpt.com"
if have scutil; then
    scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\] :/{print "  " $3}' | head -"$LIMIT"
fi
DNS_ADDR=""
if have dscacheutil; then
    DNS_ADDR=$(dscacheutil -q host -a name chatgpt.com 2>/dev/null | awk '/ip_address:/{printf "%s ", $2}')
    line "chatgpt.com решается в: ${DNS_ADDR:-не определён}"
fi
case "$DNS_ADDR" in
    *8.47.69.*|*8.6.112.*) line "ВНИМАНИЕ: это адрес-заглушка провайдера (подмена DNS), а не настоящий сервер ChatGPT." ;;
esac

# --- 5. Что установлено и запущено -----------------------------------------
hdr "5. VPN-приложения и расширения"
if have systemextensionsctl; then
    cnt=$(systemextensionsctl list 2>/dev/null | grep -ciE 'vpn|network')
    line "Системных сетевых расширений (VPN): $cnt"
fi
apps=""
if [ -d /Applications ]; then
    for app in /Applications/*; do
        name=$(basename "$app")
        case "$name" in
            *[Vv][Pp][Nn]*|*[Hh]app*|*[Ii]ncy*|*[Vv]2ray*|*[Cc]lash*|*[Ss]ing*|*[Ss]urge*|*[Ss]hadow*|*[Oo]utline*|*[Ww]arp*|*[Aa]mnezia*|*[Ww]ireguard*|*[Pp]roxy*|*[Tt]unnel*)
                apps="${apps}${name}; " ;;
        esac
    done
fi
line "Приложения: ${apps:-не найдены}"
if have scutil; then
    nc=$(scutil --nc list 2>/dev/null | head -"$LIMIT")
    line "Конфигурации VPN в системе:"
    [ -n "$nc" ] && printf '%s\n' "$nc" | while IFS= read -r l; do line "$l"; done
fi
if have pgrep; then
    procs=$(pgrep -fl 'happ|incy|xray|sing-box|wireguard|warp|xray-tun|v2ray' 2>/dev/null | head -"$LIMIT" | cut -c1-90)
    line "Процессы VPN: ${procs:-не найдены}"
fi

# --- 6. Файл hosts ---------------------------------------------------------
hdr "6. Файл /etc/hosts (непустые строки без комментариев)"
hosts=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' /etc/hosts 2>/dev/null | head -"$LIMIT")
if [ -n "$hosts" ]; then
    printf '%s\n' "$hosts" | while IFS= read -r l; do line "$l"; done
    printf '%s\n' "$hosts" | grep -qi 'chatgpt\|openai' && line "ВНИМАНИЕ: в hosts есть записи для ChatGPT/OpenAI."
else
    line "Записей нет."
fi

# --- 7. Проверка выхода в интернет ----------------------------------------
hdr "7. Куда выходит интернет"
TRACE=$(curl -s --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
EXIT_IP=$(printf '%s\n' "$TRACE" | awk -F= '/^ip=/{print $2}')
EXIT_LOC=$(printf '%s\n' "$TRACE" | awk -F= '/^loc=/{print $2}')
EXIT_PROTO=$(printf '%s\n' "$TRACE" | awk -F= '/^http=/{print $2}')
if [ -n "${EXIT_IP:-}" ]; then
    line "Адрес выхода (IPv4): $EXIT_IP"
    line "Страна выхода: ${EXIT_LOC:-?}"
    [ -n "${EXIT_PROTO:-}" ] && line "Протокол соединения: $EXIT_PROTO"
else
    line "Запрос не прошёл: интернета нет либо выход заблокирован."
fi

# IPv4 и IPv6 отдельно: IPv6 часто ходит мимо VPN и выдаёт российский адрес.
IPV4=$(curl -s --max-time 12 https://api.ipify.org 2>/dev/null)
IPV6=$(curl -s --max-time 12 https://api6.ipify.org 2>/dev/null)
IPV4=$(printf '%s' "$IPV4" | tr -d ' \n\r')
IPV6=$(printf '%s' "$IPV6" | tr -d ' \n\r')
line "IPv4 по запросу к api.ipify.org: ${IPV4:-нет ответа}"
line "IPv6 по запросу к api6.ipify.org: ${IPV6:-нет ответа (IPv6 не используется)}"

# --- 8. Проверка ChatGPT ---------------------------------------------------
hdr "8. Ответ chatgpt.com"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'
RES=$(curl -s -o /dev/null --max-time 20 -A "$UA" \
      -w 'код=%{http_code} время=%{time_total}с адрес=%{remote_ip}' https://chatgpt.com/ 2>/dev/null)
CHATGPT_CODE=$(printf '%s' "$RES" | awk -F'[= ]' '/код=/{print $2}')
line "${RES:-запрос не прошёл}"

# --- 9. Что это значит -----------------------------------------------------
hdr "9. Что это значит"
case "$ROUTE_IF" in
    utun*) line "VPN перехватывает весь трафик системы: да (интерфейс $ROUTE_IF)." ;;
    '')    line "Маршрут по умолчанию не определён: сети нет." ;;
    *)     line "VPN не перехватывает весь трафик: маршрут по умолчанию идёт через $ROUTE_IF." ;;
esac
case "${EXIT_LOC:-}" in
    RU) line "Интернет выходит из России: значит часть трафика идёт мимо VPN." ;;
    '') line "Выход в интернет не определён." ;;
    *)  line "Интернет выходит из страны $EXIT_LOC: адрес не российский." ;;
esac
case "$DNS_ADDR" in
    *8.47.69.*|*8.6.112.*) line "Адрес ChatGPT подменяет провайдер: соединение идёт не на сервер ChatGPT." ;;
    '') line "DNS не отдал адрес ChatGPT." ;;
    *)  line "DNS отдаёт обычный адрес ChatGPT." ;;
esac
case "$PROXY_STATE" in
    "не включён") line "Системный прокси не включён." ;;
    *) line "$PROXY_STATE — приложения могут обходить VPN через этот прокси." ;;
esac
case "${CHATGPT_CODE:-}" in
    200|403) line "Сайт ChatGPT отвечает (код $CHATGPT_CODE) — сеть до него доходит." ;;
    000|'') line "Сайт ChatGPT не ответил: соединение не устанавливается." ;;
    *)      line "Сайт ChatGPT ответил кодом $CHATGPT_CODE." ;;
esac
if printf '%s\n' "${hosts:-}" | grep -qi 'chatgpt\|openai'; then
    line "В файле hosts есть записи для ChatGPT — это может блокировать сайт."
fi
case "${IPV6:-}" in
    '') line "IPv6 не используется: весь трафик идёт по IPv4 через VPN." ;;
    *)  line "IPv6 работает и выходит с адреса $IPV6. Если этот адрес российский, часть трафика идёт мимо VPN." ;;
esac

say ""
say "Готово. Скопируйте весь текст (Cmd+A, Cmd+C) и пришлите в поддержку."
say "Если удобнее — сделайте скриншот этого окна."
# Enter ждём только когда скрипт запущен в терминале, а не через «curl | bash»
if [ -t 0 ]; then
    printf 'Нажмите Enter, чтобы закрыть окно… '
    read -r _
fi
