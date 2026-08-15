# Miao 0.8 — tap trusted via backboardd

## Idea
Safari/JS da solo **non** apre i popunder Exo.  
I tocchi “veri” li manda **backboardd** (come il dito).

Flusso:
1. Safari legge coordinate del thumb dal DOM  
2. Scrive `miao-hid.txt` + notify  
3. **backboardd** esegue gesto HID (down/move/up)  
4. Se dopo ~3s non sei su `/video/`, fallback JS  

## Install
Sileo → **0.8.0** → **Userspace Reboot** (obbligatorio: carica anche backboardd)

## Test
3× Volume. Toast: `HID x,y`.  
Se parte la **scheda ads** → ci siamo.  
Se schermo nero: prefs `DisableBackboardHID=1` oppure reinstalla 0.7.1.

## Log
`/var/mobile/Documents/miao-loaded.txt` — cerca `hid-req` / `hid-exec` / `backboardd`
