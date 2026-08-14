# Miao

Tweak **rootless** per **Dopamine** (tap da SpringBoard).  
Aggiornamenti: **repo Sileo** automatico (niente zip Actions ogni volta).

## Aggiornare dal telefono (consigliato)

1. Una volta sola — GitHub → repo **miao** → **Settings → Pages**  
   Source: Deploy from branch **`gh-pages`** / root  
   (dopo la prima CI verde compare il branch `gh-pages`)

2. Sileo → **Sources** → **+** → aggiungi:
   ```
   https://b20893513-star.github.io/miao/
   ```

3. Cerca **Miao** → **Installa** o **Upgrade**

4. App **Dopamine** → **Userspace Reboot**

Da quel momento, a ogni fix: Sileo → refresh → Upgrade. Fine.

Pagina repo: https://b20893513-star.github.io/miao/

## Test v0 (dopo install)

- Toast **«Miao attivo»** dopo reboot (se manca, in Filza controlla `Miao.dylib`)
- **3× Volume** (su o giù) → toast 1/3 → 2/3 → TAP
- Verifica marker: `/var/mobile/Documents/miao-loaded.txt`
- Controlla che Safari carichi ancora i siti

## SSH opzionale (install automatica da CI)

Sul telefono: OpenSSH, stessa Wi‑Fi del PC / raggiungibile.

In GitHub → Settings → Secrets → Actions, crea:

| Secret | Esempio |
|--------|---------|
| `PHONE_HOST` | `192.168.1.20` |
| `PHONE_PORT` | `22` (opzionale) |
| `PHONE_USER` | `mobile` (opzionale) |
| `PHONE_SSH_KEY` | chiave privata OpenSSH |

Da PC (senza CI):

```bash
export PHONE_HOST=192.168.1.20
./scripts/ssh-install.sh packages/*.deb
```

## Build locale / artifact

CI: push su `main` → artifact `miao-rootless-deb` + publish Pages.  
Manuale: `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless`

## Note

- Inject solo **SpringBoard** (non Safari) in v0
- Non è un crack di XXTouch Elite
