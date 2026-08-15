# Miao 0.8.6

## Fix
- Tap con punti schermo + `contextId` quando possibile
- Se non c'e' `BKHIDSystemInterface` (tipico in SpringBoard): **ClientDispatch con coords 0..1** (non assolute — bug che mandava i tap fuori schermo)
- `MiaoHID.m` senza Logos per backboardd

## Toast
- `HID worker SB ON` all'unlock
- `HIT` / `MISS` poi `HID-sb x,y`
- `Video OK` se naviga

## Install
Userspace Reboot dopo update.
