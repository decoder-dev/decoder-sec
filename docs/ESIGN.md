# ESign — один файл

Скачай **`DecoderSec.ipa`** (~38 МБ) из [Releases](https://github.com/decoder-dev/decoder-sec/releases).

## Установка (если «не устанавливается»)

1. **Проверь файл:** размер около **38 МБ**. Если скачался килобайтный HTML — это не IPA, скачай снова по Wi‑Fi.
2. На iPhone: **Настройки → Основные → VPN и управление устройством** — удали старые профили decoder / VPN.
3. **Настройки → VPN** — удали конфигурацию decoder sec., если осталась после удаления приложения.
4. Удали приложение decoder sec. с домашнего экрана.
5. ESign → Импорт `DecoderSec.ipa` → подпись **платным** сертификатом с **Network Extension** (app + `.appex`) → Установить.
6. Доверь сертификат при запросе → открой приложение → Connect → разреши VPN.

Бесплатный Apple ID **не** ставит VPN-приложения с Packet Tunnel — это ограничение Apple.

## Обычные шаги

1. Открой **ESign**.
2. Импорт → `DecoderSec.ipa` (полный, не lite).
3. Подпись платным сертом с `packet-tunnel-provider`.
4. Установка → конфиг / `happ://` → **Connect**.

CI IPA подписан ad-hoc **без** entitlements — ESign сам вшивает их из вашего профиля (так надёжнее при смене Bundle ID).

## Если Connect не поднимает туннель

См. Log console: строка `appex preflight … plugins=[…] matched=true`.  
`plugins=[]` → lite/битый IPA. Иначе — серт без Network Extension.
