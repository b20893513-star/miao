# Miao 0.5.1

## Fix rispetto a 0.5.0

- Click/Skip **non** usano piu' solo JS `.click()` (non apre popunder / spesso non skippa)
- Legge **coordinate dal DOM** (`getBoundingClientRect`) e fa **tap HID reale in Safari**
- Comandi via **file** `/var/mobile/Documents/miao-cmd.txt` + `notify_post` (piu' affidabile)
- Toast in Safari: `Miao Safari ON`, `CMD …`, `TAP x,y`, `Safari PONG`

## Flusso

1. HOME  
2. HID tap sulla card `/video/` (2 tentativi)  
3. Chiudi schede non-noxreel (se aperte)  
4. Skip @ ~10s (HID sul bottone Skip)  
5. Seek+scroll  
6. Chiudi extra  

## Debug

- `/var/mobile/Documents/miao-loaded.txt`  
- `/var/mobile/Documents/miao-ack.txt`  

Se non vedi mai `Miao Safari ON` / `PONG`, il tweak non e' iniettato in Safari.
