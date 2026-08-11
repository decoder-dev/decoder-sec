# ESign — один файл

Скачай **`DecoderSec.ipa`** из [Releases](https://github.com/decoder-dev/decoder-sec/releases) (полный VPN, не lite).

## Шаги

1. Открой **ESign** на iPhone.
2. Импорт → выбери `DecoderSec.ipa`.
3. Подпись **платным** сертификатом с правом **Network Extension / VPN**  
   (бесплатный Apple ID VPN не даст — это ограничение Apple, не приложения).
4. Установи → разреши VPN-профиль при первом Connect.
5. В приложении добавь конфиг (или `happ://` ссылку) → **Connect**.

Один IPA уже содержит приложение и Packet Tunnel. App Groups не нужны.  
После смены Bundle ID в ESign extension находится автоматически.

## Если Connect не поднимает VPN

Сертификат без Network Extension: приложение откроется, туннель — нет.  
Нужен платный серт/профиль с `packet-tunnel-provider` для app + extension.
