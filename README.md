# luci-app-yandex-speedtest

Карточка замера скорости до Яндекса (как [Интернетометр](https://yandex.ru/internet)) на странице
**Status → Overview** в LuCI. Замер идёт с самого роутера: загрузка и отдача в несколько потоков через `curl`.

- клик по карточке запускает тест, повторный клик останавливает;
- во время теста показывается живая скорость и полоса прогресса;
- внешний IP по умолчанию размыт, клик по нему показывает адрес;
- если API Яндекса недоступен, замер идёт через запасные серверы (Selectel / Ростелеком),
  и на карточке написано, через какие.

> Тест создаёт реальный трафик (десятки и сотни мегабайт). Учитывайте это на лимитных тарифах.

## Установка

Готовые пакеты собирает GitHub Actions: вкладка **Actions** → последняя сборка → **Artifacts**
(для тегов `v*` — в **Releases**).

OpenWrt 24.10 (opkg):

```sh
opkg install luci-app-yandex-speedtest_*.ipk luci-i18n-yandex-speedtest-ru_*.ipk
```

OpenWrt 25.12 (apk, пакеты без подписи):

```sh
apk add --allow-untrusted luci-app-yandex-speedtest-*.apk luci-i18n-yandex-speedtest-ru-*.apk
```

После установки:

```sh
rm -rf /tmp/luci-*; /etc/init.d/rpcd restart
```

Нужен `curl` (ставится зависимостью).

## Настройки

`/etc/config/yandex-speedtest`:

```
config settings 'main'
	option secs '15'          # длительность каждой фазы, 5–60 с
	option streams '3'        # число потоков, 1–8
	option iface ''           # пусто — маршрут по умолчанию; иначе интерфейс (wan, modem) или устройство (wwan0)
	option fallback_down 'https://speedtest.selectel.ru/1GB'
	option fallback_up 'https://speedtest.rt.ru/backend/empty.php'
```

## Проверка и отладка на роутере

Диагностика (ответы API Яндекса, выбранные серверы, короткая проверка загрузки и отдачи):

```sh
/usr/libexec/yandex-speedtest/worker probe
```

Тест без браузера:

```sh
ubus call yandex-speedtest start
ubus call yandex-speedtest status   # повторять, пока state не станет done
ubus call yandex-speedtest stop
```

Состояние лежит в `/tmp/yandex-speedtest/state.json`:

```json
{"state":"idle|prepare|down|up|done|error|cancelled","live":0,"down":null,"up":null,
 "ip":"","server":"yandex|fallback","hosts":"","elapsed":0,"secs":15,"ts":0,"error":""}
```

Коды ошибок: `no-curl`, `down-failed`, `up-failed`, `aborted` (worker завершился посреди теста).

## Как устроено

| Файл | Что делает |
|------|------------|
| `root/usr/libexec/yandex-speedtest/worker` | sh-скрипт замера: зонды Яндекса, потоки curl, живая скорость по счётчикам интерфейса, `state.json` |
| `root/usr/share/rpcd/ucode/yandex-speedtest.uc` | ubus-объект `yandex-speedtest`: `start`, `status`, `stop` |
| `root/usr/share/rpcd/acl.d/luci-app-yandex-speedtest.json` | права: `status` на чтение, `start`/`stop` на запись |
| `htdocs/.../view/status/include/25_yandex_speedtest.js` | карточка на Overview |
| `po/` | перевод |

План работ — в [TODO.md](TODO.md).
