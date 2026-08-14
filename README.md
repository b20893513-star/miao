# Miao — sessione Safari on-device (flusso NoxReel mobile)

## Flusso reale del sito (mobile)

1. **Home** `/` — griglia di `VideoCard`: ogni thumb è un `Link` a `/video/{slug}`. Non c’è player, un tap “al centro” non avvia nulla.
2. **Pagina video** `/video/{slug}` — `VideoPlayer`: eventuale preroll VAST → html ads → content con autoplay `playsInline`.
3. **View** — `ViewTracker` conta all’apertura pagina; per ads/preroll il riferimento utile è ~**10s** di playback (come nello script VM).
4. **Age gate** — rimosso dal layout live (non gestito da Miao).

Quindi Miao **non** apre solo la home e tappa: scarica la home, estrae `/video/…`, apre un video a caso, aspetta, chiude schede.

## 0.4.2 — cosa fa (3× Volume)

1. GET `HomeURL` → parse link `/video/{slug}`
2. Apre Safari su un video (evita ripetuti nella stessa sessione)
3. Dopo ~5s: tap soft sulla zona player
4. Attende `WaitSeconds` (default **18**)
5. Chiude schede Safari
6. Ripete `Cycles` volte

## Install

Source: `https://b20893513-star.github.io/miao/`  
Deb: `https://b20893513-star.github.io/miao/miao-latest.deb` → Filza → Userspace Reboot

## Prefs

`/var/mobile/Library/Preferences/com.noxlab.miao.plist`

| Chiave | Default | Nota |
|--------|---------|------|
| HomeURL | https://noxreel.uk/ | Da cui leggere i video |
| VideoURL / SessionURL con `/video/` | — | Salta il fetch, usa quel video |
| WaitSeconds | 18 | Tempo sulla pagina video |
| Cycles | 1 | Cicli di fila |
| TapX / TapY | auto (zona player) | Tap soft in Safari |

## Log

`/var/mobile/Documents/miao-loaded.txt`
