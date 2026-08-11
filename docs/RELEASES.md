# Releases

## Один файл

Каждый тег `v*` публикует:

- **`DecoderSec.ipa`** — полный рабочий клиент (приложение + Packet Tunnel)
- `DecoderSec-vX.Y.Z.ipa` — то же содержимое с версией в имени

Lite больше не публикуется в релизы.

## ESign

См. [ESIGN.md](./ESIGN.md).

```text
DecoderSec.ipa → ESign → подпись с Network Extension → Install → конфиг → Connect
```

## Tags

| Pattern | Meaning |
|---------|---------|
| `vX.Y.Z` | Stable |
| `vX.Y.Z-beta.N` | Prerelease |

```bash
git tag -a v0.1.0-beta.8 -m "decoder sec. v0.1.0-beta.8"
git push origin v0.1.0-beta.8
```
