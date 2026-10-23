# VsemDOSTUP — диагностика для клиентов

Здесь два скрипта: для macOS и для Windows. Оба **только читают** настройки сети и делают
до 6 сетевых GET-запросов к публичным адресам. Ничего не меняют, ничего не устанавливают,
файлов не создают, ключей и паролей не печатают. Пароль администратора не нужен.

## Выберите систему

| система | папка | файл |
|---|---|---|
| macOS (Apple) | [`macos/`](macos/) | `collect_macos_diag.command` |
| Windows | [`windows/`](windows/) | `collect_windows_diag.ps1` |

В каждой папке — инструкция по шагам и готовая команда для копирования.

## Прямые ссылки на файлы

- macOS: `https://raw.githubusercontent.com/VladimirNNOV/vsemdostup-support/main/macos/collect_macos_diag.command`
- Windows: `https://raw.githubusercontent.com/VladimirNNOV/vsemdostup-support/main/windows/collect_windows_diag.ps1`

## Что общего в отчётах

1. Версия системы и архитектура.
2. Системный прокси.
3. Маршрут по умолчанию: идёт ли трафик через VPN.
4. DNS и адрес `chatgpt.com`: настоящий, подмена провайдера или внутренний адрес VPN.
5. VPN-программы, подключения, процессы.
6. Файл `hosts`.
7. Выход в интернет: адрес, страна, IPv4 и IPv6.
8. Ответ `chatgpt.com` по имени и по настоящему адресу.
9. Итог простыми словами: что именно сломано — DNS, маршрут, канал или браузер.
