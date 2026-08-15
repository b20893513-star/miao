# Miao 0.8.3

## Perché vedevi `Fallback JS video` e zero ads
1. Exo popunder su noxreel usa **click trusted** sul document (`/x/pop`, trigger_method 1).
2. `location.assign('/video/...')` apre il video **senza** quel click → **niente popunder**.
3. I tap HID usavano coordinate **viewport DOM** come se fossero **schermo** (manca offset barra Safari) → spesso miss → scattava il fallback JS.

## Fix 0.8.3
- Tap principale **in Safari**: `BKSHIDEventSetDigitizerInfo` + `UIApplication _enqueueHIDEvent:` (stesso schema WebKitTestRunner / iOS 16).
- Conversione **viewport → finestra** via `WKWebView convertPoint:toView:nil`.
- Backup ancora via **MiaoHID** in backboardd (coords corrette).
- **Niente** `location.assign` di default (rompe gli ads). Solo se in prefs metti `AllowJSVideoFallback = 1`.

## Dopo install
Userspace Reboot → 3× Vol.

## Toast attesi
- `TapOK x,y` = enqueue Safari riuscito (ideale)
- `HID-bb x,y` = solo backboardd vivo
- `Tap miss (no JS)` = gesture non ha navigato (meglio di JS senza ads)
- `JS video (NO ads)` = solo se hai abilitato il fallback in prefs

## Prefs (`com.noxlab.miao.plist`)
- `AllowJSVideoFallback` (bool, default no)
- `DisableBackboardHID` (bool)
