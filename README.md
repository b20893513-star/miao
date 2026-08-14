# Miao 0.5 — flusso mobile NoxReel

## Cosa faceva male (0.4.x)

- Entrava **diretto** su `/video/…` → niente click home → popunder ads spesso non parte
- “Tap player” era soft-tap UIKit: **non clicca** dentro WKWebView
- “Chiudo schede” chiamava API sbagliate → **0 schede chiuse**

## Flusso 0.5 (come usi il telefono)

1. Apre **HOME** `https://noxreel.uk/`
2. Click JS + tap su una card `/video/` (può aprire **nuova scheda ads**)
3. Chiude schede **non-noxreel** (popunder)
4. Aspetta ~10s → **Skip** sull’ads pre-video
5. Azioni umane: seek +10s, scroll, a volte altro video
6. Chiude schede extra

Trigger: **3× Volume** (Home Screen / SpringBoard).

## Prefs

`/var/mobile/Library/Preferences/com.noxlab.miao.plist`

- `HomeURL` — default `https://noxreel.uk/`
- `WaitSeconds` — secondi dopo lo Skip (default 18)
- `Cycles` — cicli
- `HomeTapX` / `HomeTapY` — fallback tap card
- `SkipTapX` / `SkipTapY` — fallback tasto Skip

## Log

`/var/mobile/Documents/miao-loaded.txt` — tab URL, evalJS, closed count

## Install

`https://b20893513-star.github.io/miao/` → Miao **0.5.0** → Userspace Reboot
