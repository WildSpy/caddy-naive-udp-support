# enable-naive-udp.sh

Скрипт для замены установленного `caddy-naive` на сборку Caddy с поддержкой UDP для `naiveproxy`.

Скрипт собирает новый бинарник Caddy через `xcaddy` с одной из модифицированных версий `forwardproxy` под платформу сервера, проверяет конфиг новым бинарником, делает резервную копию текущего бинарника, заменяет его и перезапускает `systemd`-сервис. Если сервис не запустился, изменения автоматически откатываются.

## Варианты forwardproxy

При запуске скрипт предлагает выбрать одну из версий:

| Вариант   | Репозиторий                                                                   | Особенности                                                                                     |
|-----------|-------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| `awow`    | [aUsernameWoW/forwardproxy@naive](https://github.com/aUsernameWoW/forwardproxy) | Опции `udp_uri_template` и `passthrough_uot`, UoT можно передавать в SOCKS5-upstream            |
| `zedifen` | [zedifen/forwardproxy@naive](https://github.com/zedifen/forwardproxy)           | Caddy с патчем sing-quic BBRv1 для HTTP/3, CONNECT-UDP и UoT включены всегда, без доп. опций    |

### Особенности zedifen

- Собирается строго на той версии Caddy, которая указана в файле `CADDY_VERSION` репозитория. Скрипт клонирует Caddy этой версии и накладывает на него `caddy-sing-quic-bbrv1.patch`.
- Требует Go `>= 1.26`. Если в системе Go `>= 1.21` (например, `golang-go` из репозитория Ubuntu), нужный toolchain скачается автоматически через `GOTOOLCHAIN=auto`. С более старым Go скрипт остановится и попросит установить свежий Go с [go.dev/dl](https://go.dev/dl/).
- Опций `udp_uri_template` и `passthrough_uot` нет. Если они есть в Caddyfile, скрипт покажет эти строки и предложит закомментировать их, предварительно сохранив оригинал конфига.
- CONNECT-UDP работает только по шаблону `/.well-known/masque/udp/{host}/{port}/`. Если раньше в `udp_uri_template` был другой путь, клиентов нужно перенастроить.

> **Важно, если в конфиге задан `upstream`.** В zedifen UoT всегда обрабатывается на самом сервере, поэтому UDP пойдёт напрямую с IP сервера, в обход upstream. CONNECT-UDP при заданном upstream отклоняется с ошибкой `501`. TCP по-прежнему идёт через upstream. Если UDP обязательно должен идти через upstream (например, через SOCKS5 с `passthrough_uot`), оставайтесь на варианте `awow`.

## Быстрый запуск

С интерактивным выбором версии:

```bash
curl -fsSL https://raw.githubusercontent.com/WildSpy/caddy-naive-udp-support/main/enable-naive-udp.sh | sudo bash
```

Меню читает ответ из `/dev/tty`, поэтому работает и при запуске через `curl | bash`:

```text
Выбери версию forwardproxy:
  1) aUsernameWoW/forwardproxy@naive
  2) zedifen/forwardproxy@naive (Caddy с патчем sing-quic BBRv1)

Вариант [1/2, по умолчанию 1]:
```

Без меню, сразу с нужной версией:

```bash
curl -fsSL https://raw.githubusercontent.com/WildSpy/caddy-naive-udp-support/main/enable-naive-udp.sh | sudo bash -s -- zedifen
```

Или из локального файла:

```bash
sudo bash enable-naive-udp.sh            # интерактивный выбор
sudo bash enable-naive-udp.sh awow       # aUsernameWoW
sudo bash enable-naive-udp.sh zedifen    # zedifen
sudo bash enable-naive-udp.sh --help     # справка
```

Если терминала нет (cron, CI) и версия не указана, скрипт завершится с ошибкой, а не будет ждать ввода.

## Что делает скрипт

1. Определяет версию forwardproxy: из аргумента, переменной `FORWARDPROXY` или через интерактивное меню.
2. Проверяет, что запущен от `root`.
3. Определяет целевую платформу по `uname -m` и выставляет `GOOS`, `GOARCH` и при необходимости `GOARM`.
4. Проверяет наличие Go и, если его нет, пытается установить через пакетный менеджер системы.
5. Для zedifen проверяет наличие `git` (устанавливает при необходимости) и версию Go.
6. Проверяет наличие `xcaddy`. Если его нет, устанавливает под платформу хоста:

   ```bash
   go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
   ```

7. Проверяет наличие текущего бинарника `caddy-naive`, конфига и `systemctl`.
8. Собирает новый Caddy.

   Для `awow`:

   ```bash
   xcaddy build \
     --output /root/caddy \
     --with github.com/caddyserver/forwardproxy@caddy2=github.com/aUsernameWoW/forwardproxy@naive
   ```

   Для `zedifen`:

   ```bash
   git clone --depth 1 --branch naive https://github.com/zedifen/forwardproxy.git /root/forwardproxy-zedifen
   git clone --depth 1 --branch "$(cat /root/forwardproxy-zedifen/CADDY_VERSION)" \
     https://github.com/caddyserver/caddy.git /root/forwardproxy-zedifen/.caddy-bbr
   git -C /root/forwardproxy-zedifen/.caddy-bbr apply /root/forwardproxy-zedifen/caddy-sing-quic-bbrv1.patch

   xcaddy build "$CADDY_VERSION" \
     --output /root/caddy \
     --replace github.com/caddyserver/caddy/v2=/root/forwardproxy-zedifen/.caddy-bbr \
     --with github.com/caddyserver/forwardproxy=/root/forwardproxy-zedifen
   ```

9. Для zedifen при необходимости готовит исправленный конфиг без несовместимых опций.
10. Проверяет конфиг новым бинарником через `caddy validate`. Если проверка не прошла, скрипт завершается, а работающий сервис остаётся нетронутым.
11. Останавливает текущий сервис `caddy-naive`.
12. Делает резервную копию старого бинарника (и конфига, если он менялся).
13. Устанавливает новый бинарник вместо старого.
14. При наличии `setcap` выдаёт бинарнику право слушать привилегированные порты `80` и `443`.
15. Запускает сервис `caddy-naive`. Если он не запустился, показывает логи и автоматически откатывает бинарник и конфиг.
16. Показывает статус сервиса, слушающие порты и версию установленного Caddy.

## Требования

- установленный и настроенный сервис `caddy-naive`;
- установленный текущий бинарник:

  ```text
  /usr/local/bin/caddy-naive
  ```

- конфиг сервиса:

  ```text
  /etc/caddy-naive/Caddyfile
  ```

Скрипт умеет автоматически установить Go и `git`, если в системе есть один из пакетных менеджеров:

- `apt-get`;
- `dnf`;
- `yum`.

`xcaddy` устанавливается автоматически через `go install`. Обычно после установки бинарник находится здесь:

```text
/root/go/bin/xcaddy
```

## Платформа

Архитектура определяется автоматически по `uname -m`:

| `uname -m`        | `GOARCH`  |
|-------------------|-----------|
| `x86_64`, `amd64` | `amd64`   |
| `aarch64`, `arm64`| `arm64`   |
| `armv7l`          | `arm` (`GOARM=7`) |
| `armv6l`          | `arm` (`GOARM=6`) |
| `i386`, `i686`    | `386`     |
| `s390x`           | `s390x`   |
| `ppc64le`         | `ppc64le` |
| `riscv64`         | `riscv64` |

Если автоопределение ошиблось, платформу можно задать вручную через `TARGET_OS`, `TARGET_ARCH`, `TARGET_ARM`.

Учтите: скрипт сразу устанавливает собранный бинарник на этот же сервер. Если собрать бинарник под другую архитектуру, проверка конфига будет пропущена, а сервис не запустится (и изменения откатятся).

## Настройки

Значения по умолчанию в начале скрипта:

```bash
CADDY_SERVICE="caddy-naive"
CADDY_BIN="/usr/local/bin/caddy-naive"
BUILD_DIR="/root"
NEW_CADDY="${BUILD_DIR}/caddy"
```

Где:

- `CADDY_SERVICE` — имя `systemd`-сервиса;
- `CADDY_BIN` — путь к установленному бинарнику `caddy-naive`;
- `BUILD_DIR` — директория, в которой выполняется сборка;
- `NEW_CADDY` — временный путь к новому собранному бинарнику.

Если у вас другие пути или другое имя сервиса, измените эти переменные в начале скрипта.

Переменные окружения:

| Переменная       | По умолчанию                  | Описание                                              |
|------------------|-------------------------------|-------------------------------------------------------|
| `FORWARDPROXY`   | —                             | `awow` или `zedifen`; если не задана — меню           |
| `CADDY_CONFIG`   | `/etc/caddy-naive/Caddyfile`  | Путь к конфигу сервиса                                |
| `CADDY_ADAPTER`  | `caddyfile`                   | Адаптер конфига для `caddy validate`                  |
| `TARGET_OS`      | `linux`                       | Целевая ОС (`GOOS`)                                   |
| `TARGET_ARCH`    | по `uname -m`                 | Целевая архитектура (`GOARCH`)                        |
| `TARGET_ARM`     | по `uname -m`                 | Версия ARM (`GOARM`) для `TARGET_ARCH=arm`            |
| `XCADDY`         | ищется автоматически          | Путь к бинарнику `xcaddy`                             |
| `ZEDIFEN_BRANCH` | `naive`                       | Ветка репозитория zedifen/forwardproxy                |

Пример:

```bash
curl -fsSL https://raw.githubusercontent.com/WildSpy/caddy-naive-udp-support/main/enable-naive-udp.sh \
  | sudo FORWARDPROXY=zedifen CADDY_CONFIG=/etc/caddy/Caddyfile bash
```

## Что будет с текущим бинарником и конфигом

Перед заменой старый бинарник сохраняется рядом с исходным файлом, например:

```text
/usr/local/bin/caddy-naive_old_20261016-232608
```

Если скрипт менял конфиг (только для zedifen), оригинал сохраняется так же:

```text
/etc/caddy-naive/Caddyfile_old_20261016-232608
```

Несовместимые строки не удаляются, а комментируются:

```text
            upstream socks5://127.0.0.1:1080
            # passthrough_uot
```

Точные пути показываются в конце выполнения скрипта.

## Откат

Если после замены сервис не запустился, скрипт сам покажет логи, вернёт старый бинарник (неудачный сохранит как `caddy-naive.failed`), восстановит конфиг и снова запустит сервис.

Вручную откат можно выполнить так:

```bash
systemctl stop caddy-naive
mv /usr/local/bin/caddy-naive /usr/local/bin/caddy-naive.failed
mv /usr/local/bin/caddy-naive_old_YYYYMMDD-HHMMSS /usr/local/bin/caddy-naive
# если скрипт менял конфиг:
cp /etc/caddy-naive/Caddyfile_old_YYYYMMDD-HHMMSS /etc/caddy-naive/Caddyfile
systemctl reset-failed caddy-naive
systemctl start caddy-naive
```

Замените `YYYYMMDD-HHMMSS` на реальную метку времени из вывода скрипта.

Чтобы заранее проверить, примет ли новый бинарник ваш конфиг:

```bash
/root/caddy validate --config /etc/caddy-naive/Caddyfile --adapter caddyfile
```
