# Miao

Tweak rootless Dopamine. Gli update devono arrivare da **Sileo**, non da Filza/Actions.

## Setup UNA VOLTA (poi basta Upgrade)

1. Sileo → Sources → `https://b20893513-star.github.io/miao/`
2. Cerca **Miao** → **Installa da Sileo**
3. Dopamine → **Userspace Reboot**

Se prima l’avevi messo con **Filza**, Sileo non mostra gli aggiornamenti:  
**Disinstalla Miao** → reinstalla **cercandolo nel source** → reboot.

### Dopo (normale)
Sileo → Aggiornamenti → Upgrade → Userspace Reboot.  
Niente zip, niente Actions, niente link diversi.

### Emergenza (URL sempre uguale)
https://b20893513-star.github.io/miao/miao-latest.deb

## Zero-click (SSH)
Secrets GitHub: `PHONE_HOST`, `PHONE_SSH_KEY` (+ opz. porta/user).  
A ogni build CI installa da sola sul telefono.

## Trigger
Alert “Miao” al boot · **3× Volume** = tap di prova · marker `miao-loaded.txt`
