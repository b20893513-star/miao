# Miao 0.2.0 — install pulita

Pacchetto unico: tweak + chiave SSH in `/var/mobile/.ssh/authorized_keys` (path reale).

## Wipe e reinstall (fai cosi)

### 1) Cancella il casino vecchio (Filza)
Elimina se esistono:
- `/var/mobile/.ssh` (tutta la cartella)
- `/var/jb/var/mobile/.ssh` (se c’e)
- eventuali `authorized_keys` / `miao.ssh` nei Download

### 2) Disinstalla pacchetti vecchi (Sileo)
- Disinstalla **Miao**
- Disinstalla **Miao SSH Key** se compare

### 3) Installa SOLO questo
Source Sileo: `https://b20893513-star.github.io/miao/`  
Cerca **Miao** → Installa **0.2.0**

Oppure URL fisso:  
https://b20893513-star.github.io/miao/miao-latest.deb  
→ Filza → Installer (non eseguire in NewTerm)

### 4) Dopamine → Userspace Reboot

### 5) Test
- Alert/toast **Miao**
- 3x Volume
- Da PC: SSH con chiave `miao_phone`

## Trigger
3x Volume = tap di prova
