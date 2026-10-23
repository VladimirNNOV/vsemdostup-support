#!/bin/bash
# ---------------------------------------------------------------------------
# Диагностика сети на Android (Termux) для поддержки VsemDOSTUP.
#
# Что делает: только ЧИТАЕТ настройки и делает до 12 сетевых GET-запросов
# (все к публичным адресам). Ничего не меняет, не требует root, файлов не создаёт,
# секретов не печатает.
#
# Нужен curl. Если его нет: pkg install curl -y
# Запуск: bash collect_android_diag.sh   (или через curl -fsSL <адрес> | bash)
# ---------------------------------------------------------------------------

if [ -z "${PREFIX:-}" ] || [ ! -d "${PREFIX:-/nonexistent}" ]; then
    echo "Этот скрипт работает только в Termux на Android."
    echo "Termux ставится из F-Droid: https://f-droid.org/packages/com.termux/"
    exit 1
fi

LIMIT=12
hdr() { printf '\n===== %s =====\n' "$1"; }
line() { printf '  %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

printf 'VsemDOSTUP — диагностика Android\n'
printf 'Дата и время: %s\n' "$(date '+%d.%m.%Y %H:%M:%S %Z')"

# --- 1. Устройство ---------------------------------------------------------
hdr "1. Устройство"
if have getprop; then
    line "Модель: $(getprop ro.product.model 2>/dev/null)"
    line "Производитель: $(getprop ro.product.manufacturer 2>/dev/null)"
    line "Android: $(getprop ro.build.version.release 2>/dev/null) (SDK $(getprop ro.build.version.sdk 2>/dev/null))"
fi

# --- 2. Маршрут по умолчанию и туннели -------------------------------------
hdr "2. Маршрут по умолчанию (перехватывает ли VPN весь трафик)"
DEF_LINE=""
if have ip; then
    DEF_LINE=$(ip route 2>/dev/null | awk '/^default/{print; exit}')
fi
if [ -z "$DEF_LINE" ] && [ -r /proc/net/route ]; then
    # Резерв: таблица маршрутов ядра. Нулевой адрес = маршрут по умолчанию.
    DEF_DEV=$(awk '$2=="00000000"{print $1; exit}' /proc/net/route 2>/dev/null)
    [ -n "$DEF_DEV" ] && DEF_LINE="default dev $DEF_DEV"
fi
line "Маршрут по умолчанию: ${DEF_LINE:-не определён}"
DEF_IF=$(printf '%s' "$DEF_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
case "$DEF_IF" in
    tun*|wg*|utun*|ppp*|ipsec*)
        line "Это туннель ($DEF_IF): весь трафик системы идёт через VPN." ;;
    '')
        line "Интерфейс маршрута не определён." ;;
    *)
        line "Это обычный интерфейс ($DEF_IF): трафик идёт напрямую." ;;
esac
if have ip; then
    IFACES=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(tun|wg|utun|ppp|ipsec)' | head -"$LIMIT" | tr '\n' ' ')
    line "Туннельные интерфейсы: ${IFACES:-не найдены}"
fi
VPN_PROCS=""
for p in happ incy xray sing-box wireguard v2ray amnezia openvpn; do
    if pgrep -f "$p" >/dev/null 2>&1; then VPN_PROCS="$VPN_PROCS $p"; fi
done
line "Процессы VPN: ${VPN_PROCS:-не найдены}"

# --- 3. DNS ----------------------------------------------------------------
hdr "3. DNS-серверы и адреса ИИ-сервисов"
if have getprop; then
    DNS1=$(getprop net.dns1 2>/dev/null)
    [ -n "$DNS1" ] && line "net.dns1: $DNS1"
    getprop 2>/dev/null | grep -i 'dns' | head -"$LIMIT" | while IFS= read -r l; do line "$l"; done
fi
if [ -r /etc/resolv.conf ]; then
    line "resolv.conf:"
    grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | head -"$LIMIT" | while IFS= read -r l; do line "  $l"; done
fi

# Домен, вид сервиса и настоящий адрес (сверено через DoH 1.1.1.1).
AI_SERVICES="chatgpt.com|chatgpt|104.18.32.47 claude.ai|claude|160.79.104.10 gemini.google.com|google|142.251.157.2 notebooklm.google.com|google|172.217.20.174"

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

resolve_name() {
    if have getent; then
        getent hosts "$1" 2>/dev/null | awk '{print $1}' | head -3 | tr '\n' ' '
    elif have ping; then
        ping -c 1 -W 3 "$1" 2>/dev/null | awk -F'[()]' '/\(/{print $2; exit}'
    fi
}

DNS_PROBLEMS=""
for entry in $AI_SERVICES; do
    dom=${entry%%|*}; rest=${entry#*|}; kind=${rest%%|*}; ref=${rest#*|}
    addr=$(resolve_name "$dom")
    addr=${addr% }
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
done

# --- 4. Файл hosts ---------------------------------------------------------
hdr "4. Файл hosts (непустые строки без комментариев)"
hosts=""
for f in /system/etc/hosts /etc/hosts; do
    if [ -r "$f" ]; then
        hosts=$(grep -vE '^\s*(#|$)' "$f" 2>/dev/null | head -"$LIMIT")
        line "$f:"
        if [ -n "$hosts" ]; then
            printf '%s\n' "$hosts" | while IFS= read -r l; do line "  $l"; done
        else
            line "  записей нет"
        fi
        break
    fi
done
[ -z "$hosts" ] && line "Прочитать hosts не удалось."

# --- 5. Выход в интернет ---------------------------------------------------
hdr "5. Куда выходит интернет"
if ! have curl; then
    line "curl не установлен. Выполните: pkg install curl -y"
    line "Без curl проверка адресов и сервисов невозможна."
    exit 0
fi

TRACE=$(curl -s --max-time 15 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
EXIT_IP=$(printf '%s\n' "$TRACE" | awk -F= '/^ip=/{print $2}')
EXIT_LOC=$(printf '%s\n' "$TRACE" | awk -F= '/^loc=/{print $2}')
EXIT_PROTO=$(printf '%s\n' "$TRACE" | awk -F= '/^http=/{print $2}')
line "Адрес выхода (IPv4): ${EXIT_IP:-не определён}"
line "Страна выхода: ${EXIT_LOC:-не определена}"
[ -n "$EXIT_PROTO" ] && line "Протокол соединения: $EXIT_PROTO"
IPV4=$(curl -s --max-time 12 https://api.ipify.org 2>/dev/null | tr -d ' \n\r')
IPV6=$(curl -s --max-time 12 https://api6.ipify.org 2>/dev/null | tr -d ' \n\r')
line "IPv4 по запросу к api.ipify.org: ${IPV4:-нет ответа} (может идти напрямую по правилу «РФ-сайты»)"
line "IPv6 по запросу к api6.ipify.org: ${IPV6:-нет ответа (IPv6 не используется)}"
if [ -n "$IPV4" ] && [ -n "$EXIT_IP" ] && [ "$IPV4" != "$EXIT_IP" ]; then
    line "Адреса разные: часть трафика идёт мимо туннеля. Так бывает по правилу «РФ-сайты напрямую» — это не ошибка."
fi

# --- 6. Ответ ИИ-сервисов --------------------------------------------------
hdr "6. Ответ ИИ-сервисов: ChatGPT, Claude, Gemini, NotebookLM"
UA='Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36'
CG_IF=$(ip route get 104.18.32.47 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
line "Маршрут до chatgpt.com идёт через: ${CG_IF:-не определён}"

AI_BAD=""
for entry in $AI_SERVICES; do
    dom=${entry%%|*}; rest=${entry#*|}; ref=${rest#*|}
    res=$(curl -s -o /dev/null --max-time 20 -A "$UA" -w 'код=%{http_code} время=%{time_total}с адрес=%{remote_ip}' "https://$dom/" 2>/dev/null)
    code=$(printf '%s' "$res" | awk -F'[= ]' '/код=/{print $2}')
    resip=$(curl -s -o /dev/null --max-time 20 -A "$UA" --resolve "$dom:443:$ref" -w 'код=%{http_code} время=%{time_total}с' "https://$dom/" 2>/dev/null)
    codeip=$(printf '%s' "$resip" | awk -F'[= ]' '/код=/{print $2}')
    line "$dom — ${res:-запрос не прошёл}"
    line "    по настоящему адресу $ref: ${resip:-запрос не прошёл}"
    both=0
    case "$code" in 200|204|301|302|403) case "$codeip" in 200|204|301|302|403) both=1 ;; esac ;; esac
    [ "$both" = 1 ] || AI_BAD="$AI_BAD $dom"
done
line "Время системы: $(date '+%d.%m.%Y %H:%M:%S %Z')"

# --- 7. Что это значит -----------------------------------------------------
hdr "7. Что это значит"
case "$DEF_IF" in
    tun*|wg*|utun*|ppp*|ipsec*) line "VPN перехватывает весь трафик системы: да (интерфейс $DEF_IF)." ;;
    '') line "Маршрут по умолчанию не определён: сети нет." ;;
    *)  line "VPN не перехватывает весь трафик: маршрут по умолчанию идёт через $DEF_IF." ;;
esac
case "${EXIT_LOC:-}" in
    US) line "Интернет выходит из США — как нужно для Gemini и NotebookLM." ;;
    RU) line "Интернет выходит из России: часть трафика идёт мимо VPN, Gemini и NotebookLM так не работают." ;;
    '') line "Выход в интернет не определён." ;;
    *)  line "Интернет выходит из страны $EXIT_LOC: для Gemini и NotebookLM нужен выход из США." ;;
esac
if [ -n "${DNS_PROBLEMS:-}" ]; then
    line "Подмена или отсутствие DNS у сервисов:$DNS_PROBLEMS — проверять DNS в настройках VPN и телефона."
fi
if [ -n "$AI_BAD" ]; then
    line "Не отвечают по имени и по настоящему адресу:$AI_BAD — причина в DNS, маршруте или канале."
    case "$AI_BAD" in
        *gemini*|*notebooklm*)
            [ "${EXIT_LOC:-}" != "US" ] && line "Gemini и NotebookLM работают только через США: сменить локацию на USA." ;;
    esac
else
    line "Все ИИ-сервисы отвечают и по имени, и по настоящему адресу: сеть и DNS в порядке, причина в браузере или в аккаунте."
fi
if grep -qi 'chatgpt\|openai' <<<"${hosts:-}"; then
    line "В файле hosts есть записи для ChatGPT — это может блокировать сайт."
fi
if [ -n "${IPV6:-}" ]; then
    line "IPv6 работает и выходит с адреса $IPV6. Если адрес российский, часть трафика идёт мимо VPN."
else
    line "IPv6 не используется: трафик идёт по IPv4."
fi

printf '\nГотово. Выделите весь текст и скопируйте в чат поддержки.\n'
