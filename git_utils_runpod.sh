D="/workspace/runpod-inits";
[ ! -d "$D" ] && git clone https://github.com/LucianGnn/runpod-inits.git "$D" || (cd "$D" && git fetch && git reset --hard origin/main && git clean -fd);
chmod +x "$D"/*.sh;
"$D"/main_init.sh
