# Miao 0.8.6 (locale — non pushata)

## Fix miss `HID-?` / `Miss`
Da SpringBoard, `IOHIDEventSystemClientDispatchEvent` con coords **normalizzate** non arriva a Safari.

Ora: punti **schermo** + `CAWindowServer contextIdAtPosition` + `BKSHIDEventSetDigitizerInfo` + `BKHIDSystemInterface injectHIDEvent` (fallback ClientDispatch).

## Build
Quando vuoi: push su `main` → CI, oppure `make package THEOS_PACKAGE_SCHEME=rootless` in locale.
Non e' stato pushato / buildato da questa sessione.
