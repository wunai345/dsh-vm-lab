# Command run inside the VM by dsh.ps1 and start-lab.ps1.
# dsh is installed once into ~/dsh-app (pinned version); if its launcher is missing, reinstall from scratch.
# Single-quoted here-string on purpose: $D and $HOME must reach the VM unexpanded. No double quotes (PowerShell 5.1 strips them for ssh).
$remote = @'
bash -ic 'D=$HOME/dsh-app; if [ ! -x $D/node_modules/.bin/dsh ]; then echo FIRST-TIME-INSTALL-of-dsh-about-90-small-packages-please-wait; rm -rf $D; mkdir -p $D && cd $D && npm_config_fetch_retries=5 npm_config_maxsockets=6 npm install --no-audit --no-fund @deepseek-ai/dsh@0.2.1-rc.2; fi; if [ ! -x $D/node_modules/.bin/dsh ]; then echo INSTALL-FAILED-launchers-present; ls $D/node_modules/.bin 2>/dev/null | head -20; exit 1; fi; fuser -k 3080/tcp 2>/dev/null; sleep 1; cd $D && exec ./node_modules/.bin/dsh web --no-open'
'@.Trim()
