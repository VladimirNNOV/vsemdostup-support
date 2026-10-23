# ---------------------------------------------------------------------------
# Диагностика сети на Windows для поддержки VsemDOSTUP.
#
# Что делает: только ЧИТАЕТ настройки и делает до 6 сетевых GET-запросов
# (все к публичным адресам). Ничего не меняет, ничего не устанавливает,
# файлов не создаёт, секретов не печатает.
#
# Как запустить:
#   1) в PowerShell одной строкой (см. инструкцию на странице репозитория),
#   2) либо: powershell -NoProfile -ExecutionPolicy Bypass -File <этот файл>
#   3) скопировать весь текст окна или сделать скриншот
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if ($env:OS -ne 'Windows_NT') {
    $sys = ''
    try { $sys = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription } catch { }
    if (-not $sys) { $sys = 'не Windows' }
    Write-Host "Этот скрипт работает только на Windows. Текущая система: $sys"
    exit 1
}

$Limit = 12

function Section([string]$Title) {
    Write-Host ''
    Write-Host "===== $Title ====="
}
function Line([string]$Text) {
    Write-Host "  $Text"
}
function Have([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

Write-Host 'VsemDOSTUP — диагностика Windows'
Write-Host ("Дата и время: " + (Get-Date).ToString('dd.MM.yyyy HH:mm:ss'))

# --- 1. Система -------------------------------------------------------------
Section '1. Система'
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Line ("Windows: " + $os.Caption + " (сборка " + $os.BuildNumber + ")")
} catch {
    Line "Версия Windows: не определена"
}
Line ("Архитектура: " + $env:PROCESSOR_ARCHITECTURE)

# --- 2. Системный прокси ----------------------------------------------------
Section '2. Системный прокси'
$proxyState = 'не включён'
try {
    $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    if ($ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
        $proxyState = "прокси включён: " + $ie.ProxyServer
        Line $proxyState
    }
} catch { }
if (Have 'netsh') {
    $winhttp = (& netsh winhttp show proxy 2>$null | Out-String).Trim()
    if ($winhttp -match 'Прокси-сервер|Proxy Server') {
        $line = ($winhttp -split "`r?`n" | Where-Object { $_ -match 'Прокси-сервер|Proxy Server' } | Select-Object -First 1)
        if ($line -notmatch 'Нет прокси|Direct access') {
            $proxyState = "прокси WinHTTP: " + $line.Trim()
            Line $proxyState
        }
    }
}
Line ("Итог по прокси: " + $proxyState)

# --- 3. Маршрут по умолчанию и VPN-адаптеры --------------------------------
Section '3. Маршрут по умолчанию (перехватывает ли VPN весь трафик)'
$routeIf = ''
$routeAlias = ''
try {
    $def = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
           Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
    if ($def) {
        $routeIf = [string]$def.ifIndex
        $adapter = Get-NetAdapter -InterfaceIndex $def.ifIndex -ErrorAction SilentlyContinue
        if ($adapter) { $routeAlias = $adapter.Name + ' / ' + $adapter.InterfaceDescription }
    }
} catch {
    $def = $null
}
Line ("Маршрут по умолчанию идёт через: " + $(if ($routeAlias) { $routeAlias } else { 'не определён' }))
if ($routeAlias -match 'VPN|WireGuard|Wintun|TAP|TUN|OpenVPN|Amnezia|Happ|Incy|sing-box|Xray|Outline') {
    Line 'Это VPN-адаптер: весь трафик системы идёт через VPN.'
} elseif ($routeAlias) {
    Line 'Это обычный адаптер: трафик идёт напрямую, VPN может стоять в режиме прокси.'
}

try {
    $vpn = Get-VpnConnection -ErrorAction SilentlyContinue |
           Select-Object Name, ServerAddress, ConnectionStatus
    if ($vpn) {
        Line 'VPN-подключения Windows:'
        $vpn | Select-Object -First $Limit | ForEach-Object {
            Line ("  " + $_.Name + ' — ' + $_.ConnectionStatus)
        }
    }
} catch { }

try {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceDescription -match 'VPN|WireGuard|Wintun|TAP|TUN|OpenVPN|Amnezia|Happ|Incy|sing-box|Xray|Outline' }
    if ($adapters) {
        $names = ($adapters | ForEach-Object { $_.Name + ' [' + $_.Status + ']' }) -join '; '
        Line ("VPN-адаптеры: " + $names)
    } else {
        Line 'VPN-адаптеры: не найдены'
    }
} catch { }

try {
    $procs = Get-Process -ErrorAction SilentlyContinue |
             Where-Object { $_.ProcessName -match 'happ|incy|xray|sing-box|wireguard|warp|v2ray|amnezia|openvpn|outline' } |
             Select-Object -First $Limit -ExpandProperty ProcessName
    if ($procs) {
        Line ("Процессы VPN: " + (($procs | Sort-Object -Unique) -join '; '))
    } else {
        Line 'Процессы VPN: не найдены'
    }
} catch { }

# --- 4. DNS и адрес chatgpt.com --------------------------------------------
Section '4. DNS-серверы и адрес chatgpt.com'
try {
    $dns = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.ServerAddresses } | Select-Object -First 4
    foreach ($d in $dns) {
        Line (($d.InterfaceAlias) + ': ' + (($d.ServerAddresses) -join ', '))
    }
} catch { Line 'DNS-серверы: не определены' }

$dnsAddr = ''
try {
    $res = Resolve-DnsName -Name 'chatgpt.com' -Type A -ErrorAction Stop |
           Where-Object { $_.IPAddress } | Select-Object -First 3 -ExpandProperty IPAddress
    $dnsAddr = ($res -join ' ')
} catch { }
if (-not $dnsAddr) {
    try {
        $res = [System.Net.Dns]::GetHostAddresses('chatgpt.com') |
               Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
               ForEach-Object { $_.IPAddressToString }
        $dnsAddr = ($res -join ' ')
    } catch { }
}
Line ("chatgpt.com решается в: " + $(if ($dnsAddr) { $dnsAddr } else { 'не определён' }))
$dnsClass = 'none'
if (-not $dnsAddr) {
    $dnsClass = 'none'
} elseif ($dnsAddr -match '(^|\s)(8\.47\.69\.|8\.6\.112\.)') {
    $dnsClass = 'spoof'
} elseif ($dnsAddr -match '^(240\.|198\.18\.|198\.19\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.)') {
    $dnsClass = 'fake'
} elseif ($dnsAddr -match '(^|\s)(104\.(1[6-9]|2[0-9]|3[01])\.|172\.(6[4-9]|7[01])\.|162\.159\.|188\.114\.)') {
    $dnsClass = 'cloudflare'
} else {
    $dnsClass = 'other'
}
switch ($dnsClass) {
    'spoof'      { Line 'ВНИМАНИЕ: это адрес-заглушка провайдера (подмена DNS), а не настоящий сервер ChatGPT.' }
    'fake'       { Line ("Адрес " + $dnsAddr + " — внутренний адрес VPN-приложения (fake-IP), а не сервер ChatGPT. Так и должно быть: приложение само направляет трафик в туннель.") }
    'cloudflare' { Line 'Адрес похож на настоящий сервер ChatGPT (сеть Cloudflare).' }
    'other'      { Line ("ВНИМАНИЕ: адрес " + $dnsAddr + " не похож на настоящий сервер ChatGPT (Cloudflare). Вероятна подмена DNS.") }
    default      { Line 'DNS не отдал адрес для chatgpt.com.' }
}

# --- 5. Файл hosts ----------------------------------------------------------
Section '5. Файл hosts (непустые строки без комментариев)'
$root = $env:SystemRoot
if (-not $root) { $root = $env:windir }
$hostsPath = ''
$hostsText = @()
if ($root) { $hostsPath = Join-Path $root 'System32\drivers\etc\hosts' }
try {
    $hostsText = Get-Content -Path $hostsPath -ErrorAction Stop |
                 Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') } |
                 Select-Object -First $Limit
    if ($hostsText) {
        foreach ($h in $hostsText) { Line $h.Trim() }
        if (($hostsText -join ' ') -match 'chatgpt|openai') {
            Line 'ВНИМАНИЕ: в hosts есть записи для ChatGPT/OpenAI.'
        }
    } else {
        Line 'Записей нет.'
    }
} catch {
    Line 'Файл hosts прочитать не удалось.'
}

# --- 6. Выход в интернет ----------------------------------------------------
Section '6. Куда выходит интернет'

function Get-Url([string]$Url) {
    if (Have 'curl.exe') {
        $out = & curl.exe -s --max-time 15 $Url 2>$null
        return (($out | Out-String).Trim())
    }
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        return ([string]$r.Content).Trim()
    } catch {
        return ''
    }
}

$trace = Get-Url 'https://www.cloudflare.com/cdn-cgi/trace'
$exitIp = ''
$exitLoc = ''
$exitProto = ''
if ($trace) {
    foreach ($row in ($trace -split "`r?`n")) {
        if ($row -like 'ip=*')    { $exitIp = $row.Substring(3) }
        if ($row -like 'loc=*')   { $exitLoc = $row.Substring(4) }
        if ($row -like 'http=*')  { $exitProto = $row.Substring(5) }
    }
}
if ($exitIp) {
    Line ("Адрес выхода (IPv4): " + $exitIp)
    Line ("Страна выхода: " + $(if ($exitLoc) { $exitLoc } else { '?' }))
    if ($exitProto) { Line ("Протокол соединения: " + $exitProto) }
} else {
    Line 'Запрос не прошёл: интернета нет либо выход заблокирован.'
}

$ipv4 = (Get-Url 'https://api.ipify.org')
$ipv6 = (Get-Url 'https://api6.ipify.org')
Line ("IPv4 по запросу к api.ipify.org: " + $(if ($ipv4) { $ipv4 } else { 'нет ответа' }) + ' (может идти напрямую по правилу «РФ-сайты»)')
Line ("IPv6 по запросу к api6.ipify.org: " + $(if ($ipv6) { $ipv6 } else { 'нет ответа (IPv6 не используется)' }))
if ($ipv4 -and $exitIp -and ($ipv4 -ne $exitIp)) {
    Line 'Адреса разные: часть трафика идёт мимо туннеля. Так бывает по правилу «РФ-сайты напрямую» — это не ошибка.'
}

# --- 7. Ответ chatgpt.com ---------------------------------------------------
Section '7. Ответ chatgpt.com'

function Test-ChatGpt {
    param([string]$ResolveTarget = '')
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'
    if (Have 'curl.exe') {
        $cargs = @('-s', '-o', 'NUL', '--max-time', '20', '-A', $ua)
        if ($ResolveTarget) { $cargs += @('--resolve', $ResolveTarget) }
        $cargs += @('-w', 'код=%{http_code} время=%{time_total}с адрес=%{remote_ip}', 'https://chatgpt.com/')
        $out = & curl.exe @cargs 2>$null
        return ((($out | Out-String).Trim()))
    }
    try {
        $r = Invoke-WebRequest -Uri 'https://chatgpt.com/' -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        return ('код=' + [int]$r.StatusCode)
    } catch {
        if ($_.Exception.Response) {
            return ('код=' + [int]$_.Exception.Response.StatusCode)
        }
        return 'запрос не прошёл'
    }
}

$chatIf = ''
try {
    $r = Find-NetRoute -RemoteIPAddress '104.18.32.47' -ErrorAction Stop | Select-Object -First 1
    if ($r) {
        $ad = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue
        if ($ad) { $chatIf = $ad.Name + ' / ' + $ad.InterfaceDescription }
    }
} catch { }
Line ("Маршрут до chatgpt.com идёт через: " + $(if ($chatIf) { $chatIf } else { 'не определён' }))

$resName = Test-ChatGpt ''
Line ("Запрос по имени: " + $(if ($resName) { $resName } else { 'запрос не прошёл' }))
$chatCode = ''
if ($resName -match 'код=(\d+)') { $chatCode = $Matches[1] }

$resIp = Test-ChatGpt '--resolve chatgpt.com:443:104.18.32.47'
Line ("Запрос к настоящему адресу 104.18.32.47: " + $(if ($resIp) { $resIp } else { 'запрос не прошёл' }))
$codeIp = ''
if ($resIp -match 'код=(\d+)') { $codeIp = $Matches[1] }

Line ("Время системы: " + (Get-Date).ToString('dd.MM.yyyy HH:mm:ss'))

# --- 8. Что это значит ------------------------------------------------------
Section '8. Что это значит'
if ($routeAlias -match 'VPN|WireGuard|Wintun|TAP|TUN|OpenVPN|Amnezia|Happ|Incy|sing-box|Xray|Outline') {
    Line 'VPN перехватывает весь трафик системы: да (' + $routeAlias + ').'
} elseif ($routeAlias) {
    Line 'VPN не перехватывает весь трафик: маршрут по умолчанию идёт через ' + $routeAlias + '.'
} else {
    Line 'Маршрут по умолчанию не определён: сети нет.'
}
if ($exitLoc -eq 'RU') {
    Line 'Интернет выходит из России: значит часть трафика идёт мимо VPN.'
} elseif ($exitLoc) {
    Line ('Интернет выходит из страны ' + $exitLoc + ': адрес не российский.')
} else {
    Line 'Выход в интернет не определён.'
}
switch ($dnsClass) {
    'fake'       { Line 'Адрес ChatGPT внутренний (fake-IP приложения): это норма, приложение само ведёт трафик в туннель.' }
    'spoof'      { Line 'Адрес ChatGPT подменяет провайдер: соединение идёт не на сервер ChatGPT.' }
    'cloudflare' { Line 'DNS отдаёт настоящий адрес ChatGPT.' }
    'other'      { Line 'Адрес ChatGPT не похож на настоящий: вероятна подмена DNS на стороне провайдера или роутера.' }
    default      { Line 'DNS не отдал адрес ChatGPT.' }
}
if ($chatIf) {
    if ($chatIf -match 'VPN|WireGuard|Wintun|TAP|TUN|OpenVPN|Amnezia|Happ|Incy|sing-box|Xray|Outline') {
        Line 'Запрос к ChatGPT система отправляет в туннель (' + $chatIf + ').'
    } else {
        Line 'Запрос к ChatGPT система отправляет НЕ в туннель, а через ' + $chatIf + ' — вот причина отказа.'
    }
} else {
    Line 'Маршрут до ChatGPT не определён.'
}
if ($chatCode -eq '200' -or $chatCode -eq '403') {
    if ($codeIp -eq '200' -or $codeIp -eq '403') {
        Line 'ChatGPT доступен и по имени, и по настоящему адресу: сеть и DNS в порядке, причина в браузере.'
    } else {
        Line ('По имени сайт отвечает (код ' + $chatCode + '), по настоящему адресу — нет. Разбирать DNS и правило маршрута.')
    }
} elseif (-not $chatCode -or $chatCode -eq '000') {
    Line 'Сайт ChatGPT не ответил ни по имени, ни по адресу: соединение не устанавливается.'
} else {
    Line ('Сайт ChatGPT ответил кодом ' + $chatCode + '.')
}
if ($proxyState -ne 'не включён') {
    Line ($proxyState + ' — приложения могут обходить VPN через этот прокси.')
} else {
    Line 'Системный прокси не включён.'
}
if ($ipv6) {
    Line ('IPv6 работает и выходит с адреса ' + $ipv6 + '. Если этот адрес российский, часть трафика идёт мимо VPN.')
} else {
    Line 'IPv6 не используется: трафик идёт по IPv4.'
}

Write-Host ''
Write-Host 'Готово. Скопируйте весь текст окна и пришлите в поддержку.'
Write-Host 'Если удобнее — сделайте скриншот этого окна.'
if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    Write-Host 'Нажмите Enter, чтобы закрыть окно…'
    [void](Read-Host)
}
