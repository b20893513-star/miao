# Miao 0.7

## Realta' sul device
I tap HID **non aprono** i link in Safari/WKWebView (solo lo scroll JS funzionava).

## Cosa fa 0.7
1. HOME  
2. **JS** `location.assign(/video/...)` (+ tentativo click)  
3. **Backup** `openURL` dello stesso video da SpringBoard  
4. **Skip** con `button.click()` JS (non HID)  
5. Seek +10 + scroll  
6. Chiudi schede ads (best effort)  

I popunder Exo (scheda ads al tap) restano difficili senza dito reale: qui almeno **entri nel video e skippi**.

## Install
Sileo refresh → Miao **0.7.0**  
oppure https://b20893513-star.github.io/miao/miao-latest.deb
