# Miao

Tweak **rootless** per **Dopamine** (iOS 15–16): tap simulato da SpringBoard.  
Ispirato allo stile XXTouch (automazione tap), ma **codice nostro** — non crack / non reverse di XXTouch Elite.

> **v0** = prova su Home. Inject **solo SpringBoard** (non Safari), per ridurre il rischio di rompere i siti come ZXTouch/AutoTouch.

## Cosa fa (v0)

| Azione | Effetto |
|--------|---------|
| **3× Volume DOWN** entro ~1.2s | Tap alle coordinate in config |
| `notifyutil -p com.noxlab.miao.tap` | Stesso tap |
| Config plist | `TapX` / `TapY` in points |

Default senza config: tap verso la zona icone Home (non il centro assoluto).

## Build senza Mac (GitHub Actions)

1. Pusha questo repo su GitHub (es. `b20893513-star/miao`).
2. Tab **Actions** → workflow **Build Miao** → **Run workflow** (o push su `main`).
3. Scarica l’artifact **`miao-rootless-deb`**.
4. Sul telefono: Filza → apri il `.deb` → installa → **Respring** (`sbreload` o Dopamine).

### Build locale (se hai Mac + Theos)

```bash
export THEOS=~/theos
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

## Install e test (ordine importante)

1. Installa il `.deb` rootless (`iphoneos-arm64`).
2. Respring.
3. **Home**: 3× Volume DOWN → deve muoversi/tapparsi qualcosa (icona / area).
4. **Subito dopo**: apri Safari → `https://noxreel.uk` (o qualsiasi sito).  
   - Se **non carica** → disinstalla Miao e segnala: v0 ha comunque rotto qualcosa (improbabile con filter solo SB, ma possibile via HID globale).
5. Se Home OK e Safari OK → possiamo passare a **v1** (tap con Safari in foreground / script loop).

### Config coordinate

Copia `config.example.plist` in:

`/var/mobile/Library/Preferences/com.noxlab.miao.plist`

Modifica `TapX` / `TapY` (points). iPhone 11 Pro Max ≈ **414×896**.

## Perché non iniettiamo Safari in v0

ZXTouch / AutoTouch injectano in Safari e sul tuo device **rompono il caricamento siti**.  
Miao v0 gira **solo in SpringBoard**. Il tap usa eventi HID a livello sistema: se anche così Safari muore, lo documentiamo e cambiamo approccio (daemon isolato / altro path).

## Roadmap

- [x] v0 — tap fisso + trigger volume / notify
- [ ] v1 — sequenza tap (script plist / JSON)
- [ ] v2 — open URL Safari + wait + tap age/play (noxreel)
- [ ] v3 — loop stile `human-auto-session` (view ≥10s, gestione tab)

## Licenza / etica

Codice originale per il tuo lab. **Non** includere crack di XXTouch Elite o altri tool a pagamento.

## Disclaimer

Automazione UI su device jailbroken può essere instabile. Usala solo sul **tuo** iPhone e sui **tuoi** siti.
