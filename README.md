# Miao 0.8.1

## Fix
`backboardd` non e' un Bundle: con solo `Bundles` **non veniva iniettato**.  
Ora: `Executables = (backboardd)`. Comandi HID su `/var/tmp/miao-hid.txt` (leggibile dal daemon).

## Dopo install
**Userspace Reboot** obbligatorio.

## Verifica
- Toast `HID x,y` = Safari manda coords  
- Toast `HID? backboardd OFF` = daemon non vivo  
- File `/var/tmp/miao-bb-alive.txt` deve esistere  
- Log `/var/tmp/miao-bb.log` con `hid-exec`

Se `backboardd OFF` → l'iniezione daemon non prende: dimmelo.
