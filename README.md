# Miao 0.8.2

## Perché `HID? backboardd OFF`
Una sola dylib con **UIKit** iniettata in `backboardd` spesso **non carica** (crash/load fail) → niente file alive → toast OFF → **nessun tap trusted** → **niente ads/popunder**.

## Fix 0.8.2
Due dylib nello stesso `.deb`:

| Dylib | Processo | Ruolo |
|-------|----------|--------|
| `Miao.dylib` | SpringBoard + Safari | sessione, JS, scrive coords |
| `MiaoHID.dylib` | **solo** backboardd | gesto HID (IOKit, **no UIKit**) |

## Dopo install
1. Sileo → aggiorna → **Userspace Reboot** (obbligatorio)
2. Apri Safari su noxreel → **3× Volume**
3. Al tap thumb: toast deve essere **`HID x,y`**, non `backboardd OFF`

## Verifica (NewTerm / Filza)
- Esiste `/var/tmp/miao-bb-alive.txt` **oppure** prefs `com.noxlab.miao.bb.plist` con `alive=1`
- Log `/var/tmp/miao-bb.log` con riga `MiaoHID online` e poi `exec norm=...`
- In `/var/jb/Library/MobileSubstrate/DynamicLibraries/` ci sono **entrambe** `Miao.dylib` e `MiaoHID.dylib` (+ `.plist`)

Se ancora OFF dopo reboot: dimmi se `MiaoHID.dylib` e `miao-bb-alive.txt` ci sono.
