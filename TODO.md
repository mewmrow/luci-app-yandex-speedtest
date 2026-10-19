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
| Перевод                | `po/ru/internetometer.po`                    | `po/ru/yandex-speedtest.po` + `po/templates/yandex-speedtest.pot` (пакет `luci-i18n-yandex-speedtest-ru`) |
| Lock                   | `/var/lock/internetometer`                   | `/tmp/yandex-speedtest/lock/` (каталог + pid)              |
| Рабочий каталог        | `/tmp/internetometer/`                       | `/tmp/yandex-speedtest/`                                   |
| CSS-префикс            | `.ito-`                                      | `.ys-` (размытие IP — `.ys-masked`, см. этап 4)            |

## Статус

Этапы 1–4 написаны (версия `0.1.0`), можно ставить на роутер и проверять минимальный функционал.
Проверено без роутера: worker — на `dash` против локального сервера с ограничением скорости
(3 потока × 20 Мбит/с → 60.0 Мбит/с), rpcd-плагин — на ucode, собранном из исходников,
виджет — в Chromium с заглушками LuCI (в том числе после минификации `jsmin` из LuCI).
CI собирает `.ipk` (24.10) и `.apk` (25.12) вместе с пакетом перевода; содержимое пакетов
печатается в аннотации сборки.

Первый тест на роутере (aarch64, uplink `phy1-sta0`, Москва): карточка 85.6 ↓ / 101.6 ↑,
браузерный Интернетометр 84.04 ↓ / 96.70 ↑ — расхождение +2% / +5%. Ответ `get-probes`
сохранён в `docs/samples/get-probes.json`; по нему исправлен regex зондов (у основных
ссылок перед `/probes/` есть сегмент пути, раньше подхватывался только `fallbackUrl`).

Отступления от исходного плана (с причинами):
- lock — не `lock` из busybox, а `mkdir` + pid: `lock` держит отдельный процесс, и после `kill -9`
  worker'а блокировка остаётся до перезагрузки; pid-файл ещё и позволяет rpcd увидеть, что worker умер;
- вместо `curl -Z` — N параллельных циклов `curl`: каждый поток перезапускает загрузку, пока не
  истечёт `secs` (50 МБ кончаются раньше 15 с уже на ~27 Мбит/с на поток);
- итог считается по `size / (time_total − time_starttransfer)` каждого потока, т.е. без TLS-рукопожатия;
- отдача — `curl -T -` (поток из `/dev/zero`, chunked), а не `--data-binary`, который держит всё тело в памяти;
- добавлены состояние `prepare`, поля `server`/`hosts`, ошибка `aborted`;
- в запасных URL разрешены `http://` и `https://` (не только https);
- класс размытия IP — `.ys-masked`, потому что `.hidden` в темах LuCI — это `display: none`.

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

- [x] Команда `worker probe`: печатает ответы `get-probes` и `ip`, что из них вырезано,
      и делает пробную загрузку (3 с) и отдачу (1 МиБ) по выбранным ссылкам.
- [x] Запустить `worker probe` на роутере, сохранить вывод в `docs/samples/` и по нему
      проверить regex зондов.
- [x] Заголовки: хватает `User-Agent`, без `Referer` и cookies API отвечает нормально.
- [x] `/probes/50mb?…` и `/upload?…` работают из `curl` без браузера; одна ссылка
      выдерживает несколько потоков и повторы (тест на роутере шёл в 3 потока).
- [ ] `get-probes` отдаёт 3 узла (разные `lid`: rumsk03, ruvoz01, m9-15) и `latency`-зонды
      `/ping`. Сейчас берётся первый узел; выбирать узел с минимальной задержкой по `/ping`,
      как это, видимо, делает браузер.
- [ ] Отдача: у зонда есть `size=30720` и отдельные `postUrl` / `websocketUrl`. Сейчас POST
      идёт на `url` (`/upload?…`) и сервер принимает тело любого размера — проверить, не
      честнее ли `postUrl`.
- [ ] Проверить, что запасные серверы (Selectel, Ростелеком) живы и не режут скорость.

**Готово, когда:** есть образцы ответов и понятен минимальный curl-запрос для каждой фазы. ✅

## Этап 1. Каркас пакета и сборка (сразу, чтобы CI работал с первого коммита)

- [x] `Makefile`:
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
- [x] `/etc/config/yandex-speedtest` помечен как conffile (`Package/.../conffiles` в Makefile,
      luci.mk сам этого не делает), чтобы не затирался при обновлении.
- [x] Пустые заглушки worker / `.uc` / ACL / виджета, чтобы пакет собирался и ставился.
- [x] `.github/workflows/build.yml`, матрица из двух SDK (пакет `all`, хватает x86_64):
  - **24.10** (opkg) → `luci-app-yandex-speedtest_*.ipk`;
  - **25.12** (apk) → `luci-app-yandex-speedtest-*.apk`.
- [x] Шаги CI: скачать SDK → `./scripts/feeds update luci packages && ./scripts/feeds install luci-base`
      → положить репозиторий в `package/luci-app-yandex-speedtest` (имя каталога важно:
      luci.mk берёт имя пакета из него)
      → `make defconfig` → `make package/luci-app-yandex-speedtest/compile V=s`.
- [x] Сборка на push/PR — артефакты в workflow; на тег `v*` — оба файла в GitHub Release.
- [x] Перевод: `po/ru` компилируется в `.lmo` при сборке (нужен host-`po2lmo` из `luci-base`).

**Готово, когда:** CI собирает пакет ✅ в `.ipk` и `.apk`, оба ставятся на роутер.

## Этап 2. Worker (`/usr/libexec/yandex-speedtest/worker`, sh + curl)

Запуск и защита:
- [x] Один экземпляр: `mkdir /tmp/yandex-speedtest/lock` + pid (если занято живым worker'ом — выйти,
      не трогая `state.json`; блокировку мёртвого — забрать), снимать в `trap` на выходе.
- [x] Нет `curl` → записать `{"state":"error","error":"no-curl"}` и выйти.
- [x] Настройки читать из uci (`config_load yandex-speedtest`), с дефолтами на случай пустого конфига.
- [x] Опция `iface`: пусто — маршрут по умолчанию, иначе `curl --interface "$iface"`.

Выбор серверов:
- [x] Перед каждым замером запрашивать зонды `get-probes`.
- [x] Ссылки вырезать строгой regex: хост `*.cdn.yandex.net`, путь `/probes/50mb?…`
      или `/upload?…`; зонды с `timeout=` отбрасывать.
- [x] Зонды не пришли / не прошли regex → загрузка с `fallback_down`, отдача на `fallback_up`.
- [x] Писать в состояние, через какой сервис реально идёт замер: `server: "yandex" | "fallback"`
      (+ хост), чтобы карточка показывала правду.

Замер:
- [x] Загрузка: `streams` параллельных циклов `curl`, каждый качает заново, пока не истечёт `secs`
      (`--max-time` на остаток), вывод в `/dev/null`.
- [x] Отдача: POST'ы из `/dev/zero` (`curl -T -`) в цикле до истечения `secs`, `-H 'Expect:'`;
      размер следующего POST удваивается (1 → 32 МиБ), пока запрос короче 2 с.
- [x] Живая скорость: раз в 500 мс прирост `rx_bytes` / `tx_bytes` из
      `/sys/class/net/$dev/statistics`; `$dev` — из `ip route get <IP зонда>`
      (IP узнать через `nslookup` или `%{remote_ip}` у первого curl). При заданном `iface` — сам `iface`.
- [x] Итог фазы: по `-w '%{size_download} %{time_total} %{time_starttransfer}'` / `%{size_upload}`
      самого curl (сумма скоростей потоков), а не по счётчикам интерфейса — так не мешает чужой трафик.
- [x] Внешний IP: `https://yandex.ru/internet/api/v0/ip`, валидировать IPv4
      (4 октета, каждый ≤ 255) или IPv6; иначе пусто.

Остановка и состояние:
- [x] Стоп: флаг `/tmp/yandex-speedtest/stop` проверяется в каждом цикле; при флаге —
      kill своих curl (PID-ы запоминать, не `killall curl`), `state: "cancelled"`.
- [x] Состояние атомарно (`state.json.tmp` + `mv`) в `/tmp/yandex-speedtest/state.json`:
  ```json
  {"state":"idle|prepare|down|up|done|error|cancelled","live":0,"down":null,"up":null,
   "ip":"","server":"yandex|fallback","hosts":"","elapsed":0,"secs":15,"ts":0,"error":""}
  ```
  `live`, `down`, `up` — Мбит/с; `elapsed` — секунды с начала текущей фазы; `ts` — unix-время.
- [x] Отладка: `worker` можно запустить руками из консоли и смотреть `state.json`.

**Готово, когда:** `/usr/libexec/yandex-speedtest/worker` из консоли даёт `done` с цифрами,
близкими к браузерному Интернетометру, а флаг `stop` прерывает его за ≤1 с.
*Локально проверено против тестового сервера; на роутере и с Яндексом — ещё нет.*

## Этап 3. API (`yandex-speedtest.uc`, rpcd-ucode)

- [x] ubus-объект `yandex-speedtest`:
  - `start` — если тест уже идёт (lock занят / `state` = `down|up`), ничего не запускать
    и вернуть текущее состояние; иначе удалить флаг `stop`, запустить worker отвязанно
    (`sh -c '/usr/libexec/yandex-speedtest/worker </dev/null >/dev/null 2>&1 &'`) и сразу ответить;
  - `status` — отдать `state.json`; битый или отсутствующий файл → удалить, отдать `idle`;
    тест «идёт», а worker мёртв → `error: "aborted"`;
  - `stop` — поставить флаг остановки.
- [x] ACL `luci-app-yandex-speedtest.json`: `status` — в `read`, `start` и `stop` — в `write`.
      Exec файлов не разрешать (всё только через ubus).
- [ ] Проверка: `/etc/init.d/rpcd restart`, затем
      `ubus call yandex-speedtest start` и `ubus call yandex-speedtest status`.

**Готово, когда:** через `ubus` можно запустить, опросить и остановить тест; повторный
`start` во время теста не запускает второй worker.

## Этап 4. Виджет (`25_yandex_speedtest.js`)

Каркас:
- [x] `baseclass` с `title`, `load()` и `render()`; вызовы через `rpc.declare`
      (`object: 'yandex-speedtest'`, методы `start` / `status` / `stop`).
- [x] DOM карточки создаётся один раз, `render()` всегда возвращает этот же элемент
      (Overview перерисовывает блоки каждые 5 секунд — иначе сбросится анимация и состояние).

Вид и поведение:
- [x] Строка с источником замера («Yandex» или имя запасного сервиса из `server`),
      затем `19.9 ↓ | 2.9 ↑ Mbps`, затем IP.
- [x] Клик по карточке запускает тест, повторный клик останавливает.
- [x] Пока идёт тест: опрос `status` раз в секунду (`poll.add` / `poll.remove`),
      плавная анимация числа к `live`, полоса прогресса по `elapsed / secs`.
- [x] При открытии страницы один раз вызвать `status`: тест идёт → подхватить его
      (в т.ч. запущенный из другой вкладки); закончен → показать последний результат.
- [x] Ошибки текстом на карточке: «Тест не удался», «Нужен curl: apk add curl / opkg install curl».

IP по умолчанию заблюрен:
- [x] `.ys-ip.ys-masked { filter: blur(5px); user-select: none; }` (не `.hidden`: в темах LuCI
      это `display: none`).
- [x] Клик по IP переключает `ys-masked` и вызывает `ev.stopPropagation()`, чтобы не запустить тест.
- [x] Подсказка (title) «Нажмите, чтобы показать IP».
- [x] После перезагрузки страницы IP снова скрыт (состояние не сохранять).
- [x] Во время теста и в результате IP тоже скрыт, пока по нему не нажали.

Оформление:
- [x] Стили через CSS-переменные темы LuCI, без жёстких цветов; стили вставлять один раз.
- [ ] Проверить bootstrap, argon, material — светлую и тёмную темы, узкий экран.

**Готово, когда:** карточка на Overview работает от клика до результата, переживает
5-секундные перерисовки и перезагрузку страницы во время теста.

## Этап 5. Настройки и перевод

- [x] uci `/etc/config/yandex-speedtest`:
  ```
  config settings 'main'
  	option secs '15'
  	option streams '3'
  	option iface ''
  	option fallback_down 'https://speedtest.selectel.ru/1GB'
  	option fallback_up 'https://speedtest.rt.ru/backend/empty.php'
  ```
- [x] Ограничить значения в worker: `secs` 5–60, `streams` 1–8, URL только `http(s)://`.
- [x] Строки в коде на английском через `_()`, `po/templates/yandex-speedtest.pot` +
      русский перевод в `po/ru/yandex-speedtest.po`.
- [ ] (Опционально, позже) страница настроек в LuCI вместо правки uci руками.

## Этап 6. Проверка

- [ ] Замер через модем и через проводной WAN совпадает с браузерным Интернетометром (±15%).
      *Через Wi-Fi uplink — совпадает (+2% / +5%); модем и проводной WAN — ещё не проверены.*
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

- [x] README: что это, установка (скриншот — после проверки на роутере):
  - `.ipk`: `opkg install luci-app-yandex-speedtest_*.ipk`;
  - `.apk` (без подписи): `apk add --allow-untrusted luci-app-yandex-speedtest-*.apk`;
  - после установки: `rm -rf /tmp/luci-*; /etc/init.d/rpcd restart`.
- [x] README: настройки uci и что тест создаёт реальный трафик (важно на лимитных тарифах).
- [ ] Тег `v1.0.0` → CI выкладывает `.ipk` и `.apk` в GitHub Release.

---

## Первая проверка на роутере (минимум)

1. Скачать из Actions пакеты под свою версию OpenWrt, поставить (см. README), выполнить
   `rm -rf /tmp/luci-*; /etc/init.d/rpcd restart`.
2. `/usr/libexec/yandex-speedtest/worker probe` — прислать вывод (IP можно замазать).
3. `ubus call yandex-speedtest start`, через 35 с `ubus call yandex-speedtest status` → `done` и цифры.
4. Status → Overview: карточка «Тест скорости», клик — тест, повторный клик — стоп, IP размыт.
5. Сравнить цифры с yandex.ru/internet в браузере с того же подключения.

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
