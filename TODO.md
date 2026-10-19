# luci-app-yandex-speedtest — план работ

Карточка замера скорости до Яндекса (тот же замер, что делает Интернетометр
yandex.ru/internet) для **Status → Overview** в LuCI.
Отдельный пакет, без зависимостей от других приложений (в том числе от luci-app-5gmodem).

## Именование

Везде используется одно имя `yandex-speedtest`; в JS-файлах и CSS — его вариант через `_` / префикс `ys-`.

| Что                    | Было (internetometer)                        | Стало                                                      |
|------------------------|----------------------------------------------|------------------------------------------------------------|
| Пакет                  | `luci-app-internetometer`                    | `luci-app-yandex-speedtest`                                |
| uci-конфиг             | `/etc/config/internetometer`                 | `/etc/config/yandex-speedtest`                             |
| Worker                 | `/usr/libexec/internetometer/worker`         | `/usr/libexec/yandex-speedtest/worker`                     |
| rpcd-плагин            | `/usr/share/rpcd/ucode/internetometer.uc`    | `/usr/share/rpcd/ucode/yandex-speedtest.uc`                |
| ubus-объект            | `internetometer`                             | `yandex-speedtest`                                         |
| ACL                    | `acl.d/luci-app-internetometer.json`         | `acl.d/luci-app-yandex-speedtest.json`                     |
| Виджет                 | `25_internetometer.js`                       | `25_yandex_speedtest.js`                                   |
| Перевод                | `po/ru/internetometer.po`                    | `po/ru/yandex-speedtest.po` + `po/templates/yandex-speedtest.pot` |
| Lock                   | `/var/lock/internetometer`                   | `/var/lock/yandex-speedtest`                               |
| Рабочий каталог        | `/tmp/internetometer/`                       | `/tmp/yandex-speedtest/`                                   |
| CSS-префикс            | `.ito-`                                      | `.ys-`                                                     |

## Структура репозитория

Репозиторий — это сам пакет (корень = каталог пакета), поэтому `luci.mk` подключается
из фида LuCI SDK, а не относительным путём `../../luci.mk`.

```
luci-app-yandex-speedtest/
├── Makefile
├── README.md
├── root/etc/config/yandex-speedtest
├── root/usr/libexec/yandex-speedtest/worker
├── root/usr/share/rpcd/ucode/yandex-speedtest.uc
├── root/usr/share/rpcd/acl.d/luci-app-yandex-speedtest.json
├── htdocs/luci-static/resources/view/status/include/25_yandex_speedtest.js
├── po/templates/yandex-speedtest.pot
├── po/ru/yandex-speedtest.po
└── .github/workflows/build.yml
```

---

## Этап 0. Разведка API (до кода)

- [ ] Сохранить реальные ответы `https://yandex.ru/internet/api/v0/get-probes` и
      `https://yandex.ru/internet/api/v0/ip` (через браузер и через `curl` с роутера)
      в `docs/samples/`, чтобы по ним писать и проверять regex.
- [ ] Выяснить, нужны ли заголовки (`Referer`, `User-Agent`, cookies), без которых API
      отвечает иначе. Записать минимальный рабочий набор.
- [ ] Проверить, что `/probes/50mb?…` и `/upload?…` работают из `curl` без браузера,
      и сколько живёт ссылка (одноразовая или нет) — от этого зависит, хватит ли одной
      ссылки на N потоков.
- [ ] Проверить, что запасные серверы (Selectel, Ростелеком) живы и не режут скорость.

**Готово, когда:** есть образцы ответов и понятен минимальный curl-запрос для каждой фазы.

## Этап 1. Каркас пакета и сборка (сразу, чтобы CI работал с первого коммита)

- [ ] `Makefile`:
  ```make
  include $(TOPDIR)/rules.mk

  LUCI_TITLE:=Yandex speed test card for Status Overview
  LUCI_DEPENDS:=+curl +rpcd-mod-ucode
  LUCI_PKGARCH:=all

  PKG_VERSION:=1.0.0
  PKG_RELEASE:=1
  PKG_LICENSE:=Apache-2.0

  include $(TOPDIR)/feeds/luci/luci.mk

  # call BuildPackage - OpenWrt buildroot signature
  ```
  Версия `1.0.0` / релиз `1` — формат, который принимают и opkg, и apk (apk строже).
- [ ] `/etc/config/yandex-speedtest` помечен как conffile (luci.mk делает это для
      `root/etc/config/*`), чтобы не затирался при обновлении.
- [ ] Пустые заглушки worker / `.uc` / ACL / виджета, чтобы пакет собирался и ставился.
- [ ] `.github/workflows/build.yml`, матрица из двух SDK (пакет `all`, хватает x86_64):
  - **24.10** (opkg) → `luci-app-yandex-speedtest_*.ipk`;
  - **25.12** (apk) → `luci-app-yandex-speedtest-*.apk`.
- [ ] Шаги CI: скачать SDK → `./scripts/feeds update luci packages && ./scripts/feeds install luci-base`
      → положить репозиторий в `package/luci-app-yandex-speedtest`
      → `make defconfig` → `make package/luci-app-yandex-speedtest/compile V=s`.
- [ ] Сборка на push/PR — артефакты в workflow; на тег `v*` — оба файла в GitHub Release.
- [ ] Перевод: `po/ru` компилируется в `.lmo` при сборке (нужен host-`po2lmo` из `luci-base`).

**Готово, когда:** CI собирает пустой пакет в `.ipk` и `.apk`, оба ставятся на роутер.

## Этап 2. Worker (`/usr/libexec/yandex-speedtest/worker`, sh + curl)

Запуск и защита:
- [ ] Один экземпляр: `lock -n /var/lock/yandex-speedtest` (если занято — выйти, не трогая
      `state.json`), снимать lock в `trap` на выходе.
- [ ] Нет `curl` → записать `{"state":"error","error":"no-curl"}` и выйти.
- [ ] Настройки читать из uci (`config_load yandex-speedtest`), с дефолтами на случай пустого конфига.
- [ ] Опция `iface`: пусто — маршрут по умолчанию, иначе `curl --interface "$iface"`.

Выбор серверов:
- [ ] Перед каждым замером запрашивать зонды `get-probes`.
- [ ] Ссылки вырезать строгой regex: хост `*.cdn.yandex.net`, путь `/probes/50mb?…`
      или `/upload?…`; зонды с `timeout=` отбрасывать.
- [ ] Зонды не пришли / не прошли regex → загрузка с `fallback_down`, отдача на `fallback_up`.
- [ ] Писать в состояние, через какой сервис реально идёт замер: `server: "yandex" | "fallback"`
      (+ хост), чтобы карточка показывала правду.

Замер:
- [ ] Загрузка: `streams` потоков (2–4) через `curl -Z --parallel-max $streams`,
      длительность фазы `secs` (`--max-time`), вывод в `/dev/null`.
- [ ] Отдача: POST'ы из `/dev/zero` в цикле до истечения `secs`, `-H 'Expect:'`;
      размер следующего POST подстраивать под измеренную скорость (≈1 с на запрос).
- [ ] Живая скорость: раз в 500 мс прирост `rx_bytes` / `tx_bytes` из
      `/sys/class/net/$dev/statistics`; `$dev` — из `ip route get <IP зонда>`
      (IP узнать через `nslookup` или `%{remote_ip}` у первого curl). При заданном `iface` — сам `iface`.
- [ ] Итог фазы: по `-w '%{size_download} %{time_total}'` / `%{size_upload}` самого curl
      (суммой по потокам), а не по счётчикам интерфейса — так не мешает чужой трафик.
- [ ] Внешний IP: `https://yandex.ru/internet/api/v0/ip`, валидировать IPv4
      (4 октета, каждый ≤ 255) или IPv6; иначе пусто.

Остановка и состояние:
- [ ] Стоп: флаг `/tmp/yandex-speedtest/stop` проверяется в каждом цикле; при флаге —
      kill своих curl (PID-ы запоминать, не `killall curl`), `state: "cancelled"`.
- [ ] Состояние атомарно (`state.json.tmp` + `mv`) в `/tmp/yandex-speedtest/state.json`:
  ```json
  {"state":"idle|down|up|done|error|cancelled","live":0,"down":null,"up":null,
   "ip":"","server":"","elapsed":0,"secs":15,"ts":0,"error":""}
  ```
  `live`, `down`, `up` — Мбит/с; `elapsed` — секунды с начала текущей фазы; `ts` — unix-время.
- [ ] Отладка: `worker` можно запустить руками из консоли и смотреть `state.json`.

**Готово, когда:** `/usr/libexec/yandex-speedtest/worker` из консоли даёт `done` с цифрами,
близкими к браузерному Интернетометру, а флаг `stop` прерывает его за ≤1 с.

## Этап 3. API (`yandex-speedtest.uc`, rpcd-ucode)

- [ ] ubus-объект `yandex-speedtest`:
  - `start` — если тест уже идёт (lock занят / `state` = `down|up`), ничего не запускать
    и вернуть текущее состояние; иначе удалить флаг `stop`, запустить worker отвязанно
    (`sh -c '/usr/libexec/yandex-speedtest/worker </dev/null >/dev/null 2>&1 &'`) и сразу ответить;
  - `status` — отдать `state.json`; битый или отсутствующий файл → удалить, отдать `idle`;
  - `stop` — поставить флаг остановки.
- [ ] ACL `luci-app-yandex-speedtest.json`: `status` — в `read`, `start` и `stop` — в `write`.
      Exec файлов не разрешать (всё только через ubus).
- [ ] Проверка: `/etc/init.d/rpcd restart`, затем
      `ubus call yandex-speedtest start` и `ubus call yandex-speedtest status`.

**Готово, когда:** через `ubus` можно запустить, опросить и остановить тест; повторный
`start` во время теста не запускает второй worker.

## Этап 4. Виджет (`25_yandex_speedtest.js`)

Каркас:
- [ ] `baseclass` с `title`, `load()` и `render()`; вызовы через `rpc.declare`
      (`object: 'yandex-speedtest'`, методы `start` / `status` / `stop`).
- [ ] DOM карточки создаётся один раз, `render()` всегда возвращает этот же элемент
      (Overview перерисовывает блоки каждые 5 секунд — иначе сбросится анимация и состояние).

Вид и поведение:
- [ ] Строка с источником замера («Yandex» или имя запасного сервиса из `server`),
      затем `19.9 ↓ | 2.9 ↑ Mbps`, затем IP.
- [ ] Клик по карточке запускает тест, повторный клик останавливает.
- [ ] Пока идёт тест: опрос `status` раз в секунду (`poll.add` / `poll.remove`),
      плавная анимация числа к `live`, полоса прогресса по `elapsed / secs`.
- [ ] При открытии страницы один раз вызвать `status`: тест идёт → подхватить его
      (в т.ч. запущенный из другой вкладки); закончен → показать последний результат.
- [ ] Ошибки текстом на карточке: «Тест не удался», «Нужен curl: apk add curl / opkg install curl».

IP по умолчанию заблюрен:
- [ ] `.ys-ip.hidden { filter: blur(5px); cursor: pointer; user-select: none; }`.
- [ ] Клик по IP переключает `hidden` и вызывает `ev.stopPropagation()`, чтобы не запустить тест.
- [ ] Подсказка (title) «Нажмите, чтобы показать IP».
- [ ] После перезагрузки страницы IP снова скрыт (состояние не сохранять).
- [ ] Во время теста и в результате IP тоже скрыт, пока по нему не нажали.

Оформление:
- [ ] Стили через CSS-переменные темы LuCI, без жёстких цветов; стили вставлять один раз.
- [ ] Проверить bootstrap, argon, material — светлую и тёмную темы, узкий экран.

**Готово, когда:** карточка на Overview работает от клика до результата, переживает
5-секундные перерисовки и перезагрузку страницы во время теста.

## Этап 5. Настройки и перевод

- [ ] uci `/etc/config/yandex-speedtest`:
  ```
  config settings 'main'
  	option secs '15'
  	option streams '3'
  	option iface ''
  	option fallback_down 'https://speedtest.selectel.ru/1GB'
  	option fallback_up 'https://speedtest.rt.ru/backend/empty.php'
  ```
- [ ] Ограничить значения в worker: `secs` 5–60, `streams` 1–8, URL только `https://`.
- [ ] Строки в коде на английском через `_()`, `po/templates/yandex-speedtest.pot` +
      русский перевод в `po/ru/yandex-speedtest.po`.
- [ ] (Опционально, позже) страница настроек в LuCI вместо правки uci руками.

## Этап 6. Проверка

- [ ] Замер через модем и через проводной WAN совпадает с браузерным Интернетометром (±15%).
- [ ] Повторный клик останавливает тест, карточка возвращается в исходный вид.
- [ ] Две открытые вкладки не запускают два теста одновременно; вторая вкладка показывает
      идущий тест.
- [ ] Если `get-probes` недоступен (заблокировать в firewall), тест идёт через запасные
      серверы, и на карточке написан сервис, по которому реально шёл замер.
- [ ] IP скрыт после загрузки страницы, показывается по клику, и этот клик не запускает тест.
- [ ] Без `curl` на карточке понятная ошибка с командой установки.
- [ ] Пакет ставится и удаляется на 24.10 (`.ipk`) и 25.12 (`.apk`), после удаления
      не остаётся ubus-объекта и файлов в `/tmp/yandex-speedtest`.

## Этап 7. Релиз и README

- [ ] README: что это, скриншот карточки, установка:
  - `.ipk`: `opkg install luci-app-yandex-speedtest_*.ipk`;
  - `.apk` (без подписи): `apk add --allow-untrusted luci-app-yandex-speedtest-*.apk`;
  - после установки: `rm -rf /tmp/luci-*; /etc/init.d/rpcd restart`.
- [ ] README: настройки uci и что тест создаёт реальный трафик (важно на лимитных тарифах).
- [ ] Тег `v1.0.0` → CI выкладывает `.ipk` и `.apk` в GitHub Release.

---

## Порядок и оценка

| # | Этап                       | Зависит от | Оценка   |
|---|----------------------------|------------|----------|
| 0 | Разведка API               | —          | 0.5 дня  |
| 1 | Каркас + CI                | —          | 0.5–1 день |
| 2 | Worker                     | 0          | 1–2 дня  |
| 3 | rpcd API                   | 2          | 0.5 дня  |
| 4 | Виджет                     | 3          | 1–2 дня  |
| 5 | Настройки и перевод        | 2, 4       | 0.5 дня  |
| 6 | Проверка на железе         | 1–5        | 1 день   |
| 7 | Релиз                      | 6          | 0.5 дня  |

Этапы 0 и 1 можно делать параллельно. Каждый этап — отдельный коммит/PR с проверкой
из пункта «Готово, когда».
