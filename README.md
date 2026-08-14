# Miao — sessione Safari on-device

Tweak Dopamine/rootless: **3× Volume** avvia una sessione senza PC / Wi‑Fi.

## Flusso 0.4.0

1. Apre Safari su `SessionURL` (default `https://noxreel.uk/`)
2. Dopo ~4s: tap soft al centro (play) — niente age gate
3. Attende `WaitSeconds` (default 12)
4. Prova a chiudere le schede Safari
5. Ripete per `Cycles` volte

Niente HID digitizer (quello faceva schermo nero). L’IA/OCR arriva dopo.

## Install

Source Sileo: `https://b20893513-star.github.io/miao/`  
Oppure: `https://b20893513-star.github.io/miao/miao-latest.deb` → Filza → Installer → Userspace Reboot.

## Preferenze

File: `/var/mobile/Library/Preferences/com.noxlab.miao.plist`

| Chiave | Default | Nota |
|--------|---------|------|
| SessionURL | https://noxreel.uk/ | URL da aprire |
| WaitSeconds | 12 | Secondi sul video (≥5) |
| Cycles | 1 | Quante sessioni di fila |
| Mode | session | `icon` = solo apri Safari |
| TapX / TapY | centro schermo | Punto tap soft |

## Log

`/var/mobile/Documents/miao-loaded.txt`
