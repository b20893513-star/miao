# Come pubblicare su GitHub (1 volta)

Da PowerShell:

```powershell
cd C:\Users\giuse\Projects\miao

# se il commit non c'e ancora:
# $env:GIT_AUTHOR_NAME="b20893513-star"
# $env:GIT_AUTHOR_EMAIL="b20893513-star@users.noreply.github.com"
# $env:GIT_COMMITTER_NAME=$env:GIT_AUTHOR_NAME
# $env:GIT_COMMITTER_EMAIL=$env:GIT_AUTHOR_EMAIL
# git add -A
# git commit -m "Initial Miao v0"

git remote set-url origin https://github.com/b20893513-star/miao.git
git push -u origin main
```

Poi su GitHub: **Actions** → **Build Miao** → aspetta → scarica artifact `miao-rootless-deb`.
