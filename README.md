# Miao 0.8.4

## Cosa non andava in 0.8.3
Toast **TapOK** = solo `_enqueueHIDEvent` chiamato. Su iPhone reale (senza entitlement WebKitTestRunner) UIKit **ignora** quei tocchi → miss + solo lo scroll JS funzionava.

## Fix
1. Tap reale via **backboardd** (`BKHIDSystemInterface injectHIDEvent` se c’e’, altrimenti IOHID dispatch)
2. **Niente** Safari enqueue di default (`PreferSafariEnqueue=1` per forzarlo)
3. `elementFromPoint` → toast **HIT** / **MISS** prima del tap (diagnostica coords)
4. Scroll + attesa + coords fresche; un tap pulito down/up

## Toast
- `HIT a...` = coords sul thumb (bene)
- `MISS ...` = punto DOM sbagliato
- `BB x,y` = comando inviato a backboardd
- `BB OFF` = MiaoHID non vivo → Userspace Reboot
- `Video OK` = navigazione riuscita
- `Miss (BB no nav)` = HID non ha aperto il link

## Dopo install
Userspace Reboot obbligatorio. Dimmi i toast in ordine (HIT/MISS → BB → Video OK/Miss).
