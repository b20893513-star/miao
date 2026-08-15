# Miao 0.6 — tap stile dito

## Obiettivo
I tap devono avvicinarsi a un **tocco umano** (IOHID digitizer con down → micro-move → up), **solo in Safari**, coordinate dal DOM del thumb/Skip.

## Flusso (3× Volume)
1. HOME noxreel + attesa load  
2. **Gesto dito** sul thumb `/video/`  
3. Chiude schede non-noxreel (se ci sono)  
4. ~10s → gesto dito su **Skip**  
5. Seek +10 + scroll  
6. Chiude extra  

Niente `element.click()` per aprire il video (quello non è trusted).

## Toast utili
- `Miao dito ON` / `Safari OK` → Safari ha il tweak  
- `Dito x,y` → HID in corso  
- `Ads chiuse N`  

## Log
`/var/mobile/Documents/miao-loaded.txt`  
`/var/mobile/Documents/miao-ack.txt`

## Nota
Se lo schermo lampeggia/nero: Userspace Reboot e segnala — HID e' solo in Safari, non da SpringBoard.
