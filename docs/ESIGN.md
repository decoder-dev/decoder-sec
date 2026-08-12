# ESign — один файл

Скачай **`DecoderSec.ipa`** из [Releases](https://github.com/decoder-dev/decoder-sec/releases) (полный VPN, не lite).

## Шаги

1. Открой **ESign** на iPhone.
2. Импорт → выбери `DecoderSec.ipa`.
3. Подпись **платным** сертификатом с правом **Network Extension / VPN / packet-tunnel**  
   для **приложения и** `DecoderSecTunnel.appex`  
   (бесплатный Apple ID VPN не даст — это ограничение Apple, не приложения).
4. Удали старую установку decoder sec. (чтобы сбросить битый VPN-профиль).
5. Установи → при Connect разреши VPN-профиль.
6. Добавь конфиг (или `happ://`) → **Connect**.

Один IPA уже содержит приложение и Packet Tunnel. App Groups не нужны.  
После смены Bundle ID в ESign extension находится из `PlugIns/*.appex` автоматически.

## Если Connect → «Packet Tunnel did not start» / пустые логи extension

Это **не** ошибка Xray. Система не смогла запустить `.appex`:

| Причина | Что сделать |
|---|---|
| Серт без Network Extension | Платный сертификат / профиль с `packet-tunnel-provider` |
| Подписан только app, не appex | В ESign включить подпись extension |
| Поставили lite IPA | Ставить полный `DecoderSec.ipa` |
| Старый VPN-профиль | Удалить приложение → поставить заново |

В Log console ищите строку `appex preflight … plugins=[…] matched=true`.  
Если `plugins=[]` — в IPA нет Packet Tunnel. Если `matched=false` — неверный bundle id после resign.
