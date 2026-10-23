#!/bin/bash
# ---------------------------------------------------------------------------
# Диагностика сети на macOS для поддержки VsemDOSTUP.
#
# Что делает: только ЧИТАЕТ настройки и делает до 12 сетевых GET-запросов (все к публичным адресам).
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
    ifconfig 2>/dev/null | grep -E '^utun[0-9]+:|^'"$ROUTE_IF"':' | head -"$LIMIT" | while IFS= read -r l; do line "$l"; done
fi

# --- 4. DNS ----------------------------------------------------------------
hdr "4. DNS-серверы и адреса ИИ-сервисов"
if have scutil; then
    scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\] :/{print "  " $3}' | head -"$LIMIT"
fi

# Список проверяемых сервисов: домен|вид|настоящий адрес (сверено через DoH 1.1.1.1).
AI_SERVICES="chatgpt.com|chatgpt|104.18.32.47 claude.ai|claude|160.79.104.10 gemini.google.com|google|142.251.157.2 notebooklm.google.com|google|172.217.20.174"

# Принадлежит ли адрес владельцу сервиса. Нужно, чтобы отличить настоящий адрес
# от подмены: у OpenAI это Cloudflare, у Claude — 160.79.104.*, у Google — свои сети.
is_real() {
    case "$2" in
        chatgpt) case "$1" in *104.1[6-9].*|*104.2[0-9].*|*104.3[01].*|*172.6[4-9].*|*172.7[01].*|*162.159.*|*188.114.*) return 0 ;; esac ;;
        claude)  case "$1" in *160.79.104.*) return 0 ;; esac ;;
        google)  case "$1" in *142.25[0-9].*|*172.217.*|*216.58.*|*216.239.*|*172.253.*|*74.125.*|*108.177.*|*209.85.*|*64.233.*|*173.194.*) return 0 ;; esac ;;
    esac
    return 1
}

dns_class() {
    case "$1" in
        '') echo none; return ;;
        *8.47.69.*|*8.6.112.*) echo spoof; return ;;
        *240.*|*198.18.*|*198.19.*|*10.*|*192.168.*|*172.1[6-9].*|*172.2[0-9].*|*172.3[01].*|*127.*) echo fake; return ;;
    esac
    if is_real "$1" "$2"; then echo real; else echo other; fi
}

DNS_PROBLEMS=""
for entry in $AI_SERVICES; do
    dom=${entry%%|*}; rest=${entry#*|}; kind=${rest%%|*}; ref=${rest#*|}
    addr=""
    if have dscacheutil; then
        addr=$(dscacheutil -q host -a name "$dom" 2>/dev/null | awk '/ip_address:/{printf "%s ", $2}')
        addr=${addr% }
    fi
    cls=$(dns_class "$addr" "$kind")
    case "$cls" in
        spoof) line "$dom → ${addr:-нет адреса} — подмена DNS провайдером, это не сервер сервиса"
               DNS_PROBLEMS="$DNS_PROBLEMS $dom" ;;
        fake)  line "$dom → ${addr:-нет адреса} — внутренний адрес VPN-приложения (fake-IP), так и должно быть" ;;
        real)  line "$dom → $addr — настоящий адрес сервиса" ;;
        other) line "$dom → $addr — ВНИМАНИЕ: не похоже на сервер сервиса, вероятна подмена DNS"
               DNS_PROBLEMS="$DNS_PROBLEMS $dom" ;;
        none)  line "$dom → DNS не отдал адрес"
               DNS_PROBLEMS="$DNS_PROBLEMS $dom" ;;
    esac
    [ "$dom" = "chatgpt.com" ] && DNS_CLASS="$cls"
done

# --- 5. Что установлено и запущено -----------------------------------------
hdr "5. VPN-приложения и расширения"
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
    procs=$(pgrep -fl 'happ|incy|xray|sing-box|wireguard|warp|xray-tun|v2ray' 2>/dev/null | head -"$LIMIT" | cut -c1-70 | tr '\n' ';')
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
line "IPv4 по запросу к api.ipify.org: ${IPV4:-нет ответа} (может идти напрямую по правилу «РФ-сайты»)"
line "IPv6 по запросу к api6.ipify.org: ${IPV6:-нет ответа (IPv6 не используется)}"
if [ -n "${IPV4:-}" ] && [ -n "${EXIT_IP:-}" ] && [ "$IPV4" != "$EXIT_IP" ]; then
    line "Адреса разные: часть трафика идёт мимо туннеля. Так бывает по правилу «РФ-сайты напрямую» — это не ошибка."
fi

# --- 8. Ответ ИИ-сервисов --------------------------------------------------
hdr "8. Ответ ИИ-сервисов: ChatGPT, Claude, Gemini, NotebookLM"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'

CG_IF=$(route -n get chatgpt.com 2>/dev/null | awk '/interface:/{print $2}')
line "Маршрут до chatgpt.com идёт через: ${CG_IF:-не определён}"

# По каждому сервису две проверки: обычный запрос по имени и запрос к настоящему
# адресу. Если имя отвечает, а адрес нет — виноват DNS. Если оба нет — канал.
AI_OK=""
AI_BAD=""
for entry in $AI_SERVICES; do
    dom=${entry%%|*}; rest=${entry#*|}; ref=${rest#*|}
    iface=$(route -n get "$dom" 2>/dev/null | awk '/interface:/{print $2}')
    res=$(curl -s -o /dev/null --max-time 20 -A "$UA" -w 'код=%{http_code} время=%{time_total}с адрес=%{remote_ip}' "https://$dom/" 2>/dev/null)
    code=$(printf '%s' "$res" | awk -F'[= ]' '/код=/{print $2}')
    resip=$(curl -s -o /dev/null --max-time 20 -A "$UA" --resolve "$dom:443:$ref" -w 'код=%{http_code} время=%{time_total}с' "https://$dom/" 2>/dev/null)
    codeip=$(printf '%s' "$resip" | awk -F'[= ]' '/код=/{print $2}')
    line "$dom — ${res:-запрос не прошёл}, маршрут ${iface:-не определён}"
    line "    по настоящему адресу $ref: ${resip:-запрос не прошёл}"
    both=0
    case "$code" in 200|204|301|302|403) case "$codeip" in 200|204|301|302|403) both=1 ;; esac ;; esac
    if [ "$both" = 1 ]; then AI_OK="$AI_OK $dom"; else AI_BAD="$AI_BAD $dom"; fi
done

ERR=$(curl -sS -o /dev/null --max-time 20 -A "$UA" https://chatgpt.com/ 2>&1 >/dev/null | head -2)
[ -n "$ERR" ] && line "Ошибка curl к chatgpt.com: $(printf '%s' "$ERR" | tr '\n' ' ')"

line "Время системы: $(date '+%d.%m.%Y %H:%M:%S %Z')"

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
case "${DNS_CLASS:-}" in
    spoof) line "Адрес ChatGPT подменяет провайдер: соединение идёт не на сервер ChatGPT." ;;
    fake) line "Адрес ChatGPT внутренний (fake-IP приложения): это норма, приложение само ведёт трафик в туннель." ;;
    real) line "DNS отдаёт настоящий адрес ChatGPT." ;;
    other) line "Адрес ChatGPT не похож на настоящий: вероятна подмена DNS на стороне провайдера или роутера." ;;
    *) line "DNS не отдал адрес ChatGPT." ;;
esac
case "${CG_IF:-}" in
    utun*) line "Запрос к ChatGPT система отправляет в туннель ($CG_IF)." ;;
    '')    line "Маршрут до ChatGPT не определён." ;;
    *)     line "Запрос к ChatGPT система отправляет НЕ в туннель, а через $CG_IF — вот причина отказа." ;;
esac
if [ -n "${AI_BAD:-}" ]; then
    line "Не отвечают по имени и по настоящему адресу:$AI_BAD — причина в DNS, маршруте или канале, а не в браузере."
else
    line "Все ИИ-сервисы отвечают и по имени, и по настоящему адресу: сеть и DNS в порядке, причина в браузере или в аккаунте."
fi
if case "${EXIT_LOC:-}" in US) false ;; *) true ;; esac; then
    case "${AI_BAD:-}" in
        *gemini*|*notebooklm*)
            line "Gemini и NotebookLM работают только через США: сейчас выход ${EXIT_LOC:-не определён} — сменить локацию на USA." ;;
    esac
fi
case "$PROXY_STATE" in
    "не включён") line "Системный прокси не включён." ;;
    *) line "$PROXY_STATE — приложения могут обходить VPN через этот прокси." ;;
esac
if printf '%s\n' "${hosts:-}" | grep -qi 'chatgpt\|openai'; then
    line "В файле hosts есть записи для ChatGPT — это может блокировать сайт."
fi
case "${IPV6:-}" in
    '') line "IPv6 не используется: трафик идёт по IPv4." ;;
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
