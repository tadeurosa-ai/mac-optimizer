#!/bin/bash
# ============================================================
#  Testes do Mac Optimizer.
#  Uso: /bin/bash tests/run.sh
#  Isolamento: cada teste roda numa pasta temporária (HOME falso) e com
#  dublês de brew, pip3, launchctl, tmutil, sudo, df e pgrep na frente do
#  PATH. Nenhum teste chama um comando real que mexa no Mac.
#  Todos os nomes usados aqui são inventados.
# ============================================================
set -u

AQUI="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$AQUI/.." && pwd)"
SCRIPT="${SCRIPT:-$REPO/optimizer/scripts/optimizer.sh}"
SKILL="${SKILL:-$REPO/optimizer/SKILL.md}"
SHELLCHECK="$(command -v shellcheck || true)"
PATH_ORIGINAL="$PATH"
HOME_ORIGINAL="$HOME"
LINHA_INSTALACAO='mkdir -p ~/.claude/skills/optimizer/scripts && curl -fsSL https://raw.githubusercontent.com/tadeurosa-ai/mac-optimizer/main/optimizer/scripts/optimizer.sh -o ~/.claude/skills/optimizer/scripts/optimizer.sh && curl -fsSL https://raw.githubusercontent.com/tadeurosa-ai/mac-optimizer/main/optimizer/SKILL.md -o ~/.claude/skills/optimizer/SKILL.md && command rm -f ~/.claude/commands/optimizer.md && echo "Mac Optimizer instalado. Abra o Claude Code e digite /optimizer"'

PASSOU=0; FALHOU=0; PULOU=0; LISTA_FALHAS=""; LISTA_PULOS=""
ok()    { PASSOU=$((PASSOU+1)); echo "  ok    $1"; }
falha() { FALHOU=$((FALHOU+1)); LISTA_FALHAS="$LISTA_FALHAS $1"; echo "  FALHA $1 — $2"; }
# Pulado = não deu para rodar aqui (não é aprovação): aparece em separado no resultado.
pula()  { PULOU=$((PULOU+1)); LISTA_PULOS="$LISTA_PULOS $1"; echo "  PULADO $1 — $2"; }
verifica() { local nome="$1" desc="$2"; shift 2; if "$@"; then ok "$nome"; else falha "$nome" "$desc"; fi; }

AMBIENTES=""
limpar_tudo() {
  local t
  for t in $AMBIENTES; do chmod -R u+rwx "$t" 2>/dev/null; command rm -rf "$t"; done
  export HOME="$HOME_ORIGINAL" PATH="$PATH_ORIGINAL"
}
trap limpar_tudo EXIT

# ---------- dublês ----------
criar_dubles() {
  local b="$1"; mkdir -p "$b"
  cat > "$b/brew" <<'EOF'
#!/bin/bash
echo "brew $*" >> "$DUBLE_CALLS"
case "$*" in
  "cleanup --dry-run") [ "${DUBLE_BREW_NADA:-0}" = 1 ] || echo "==> This operation would free approximately 12.5MB of disk space.";;
  "cleanup --prune=all") echo "==> This operation has freed approximately 12.5MB of disk space.";;
esac
exit 0
EOF
  cat > "$b/pip3" <<'EOF'
#!/bin/bash
echo "pip3 $*" >> "$DUBLE_CALLS"
case "$*" in
  "cache dir") echo "$HOME/Library/Caches/pip";;
  "cache purge") command rm -rf "$HOME/Library/Caches/pip/"*;;
esac
exit 0
EOF
  # launchctl com estado: rótulos carregados ficam em <teste>/carregados
  cat > "$b/launchctl" <<'EOF'
#!/bin/bash
echo "launchctl $*" >> "$DUBLE_CALLS"
F="${DUBLE_CALLS%/*}/carregados"; touch "$F"
case "$1" in
  print) grep -qxF "${2##*/}" "$F"; exit $?;;
  bootout) [ "${DUBLE_BOOTOUT_FALHA:-0}" = 1 ] && exit 5
           grep -vxF "$(basename "$3" .plist)" "$F" > "$F.x"; command mv -f "$F.x" "$F"; exit 0;;
  bootstrap) basename "$3" .plist >> "$F"; exit 0;;
esac
exit 0
EOF
  cat > "$b/tmutil" <<'EOF'
#!/bin/bash
echo "tmutil $*" >> "$DUBLE_CALLS"
echo "Snapshots for disk /:"
i=0; while [ "$i" -lt "${DUBLE_TM_N:-0}" ]; do i=$((i+1)); echo "com.apple.TimeMachine.2026-01-0$i-000000.local"; done
exit 0
EOF
  cat > "$b/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> "$DUBLE_CALLS"
exit 1
EOF
  cat > "$b/df" <<'EOF'
#!/bin/bash
echo "df $*" >> "$DUBLE_CALLS"
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/disk3s5 976490576 253000000 690000000 27% /System/Volumes/Data"
EOF
  cat > "$b/pgrep" <<'EOF'
#!/bin/bash
echo "pgrep $*" >> "$DUBLE_CALLS"
[ -n "${DUBLE_PGREP_ABERTO:-}" ] && case "$*" in *"$DUBLE_PGREP_ABERTO"*) exit 0;; esac
exit 1
EOF
  cat > "$b/codex" <<'EOF'
#!/bin/bash
exit 0
EOF
  # diskutil: por padrão falha (nenhum teste lê o disco de verdade); T-SISTEMA liga o dublê completo
  cat > "$b/diskutil" <<'EOF'
#!/bin/bash
echo "diskutil $*" >> "$DUBLE_CALLS"
[ -n "${DUBLE_DISKUTIL:-}" ] || exit 1
case "$1 $2" in
  "info -plist") printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>APFSContainerReference</key><string>disk3</string></dict></plist>\n';;
  "apfs list") if [ "${3:-}" = disk3 ]; then sed -n '/^CONTAINER disk3$/,/^FIM disk3$/p' "$DUBLE_DISKUTIL"; else cat "$DUBLE_DISKUTIL"; fi;;
  *) exit 1;;
esac
EOF
  chmod +x "$b"/*
}

# Dublês das ferramentas novas (2.1.0): só existem no teste que os cria.
duble_npm() {
  cat > "$T/bin/npm" <<'EOF'
#!/bin/bash
echo "npm $*" >> "$DUBLE_CALLS"
case "$1 ${2:-}" in
  "config get")
    if [ -f .npmrc ]; then sed -n 's/^cache=//p' .npmrc; else echo "${DUBLE_NPM_CACHE:-$HOME/.npm}"; fi;;
  "cache clean")
    c=""; while [ $# -gt 0 ]; do [ "$1" = --cache ] && c="${2:-}"; shift; done
    [ "${DUBLE_NPM_DEVAGAR:-0}" = 1 ] && sleep 1
    case "${DUBLE_NPM_MODO:-normal}" in
      nao_apaga) exit 0;;
      sem_permissao) chmod 000 "$c/_cacache"; exit 0;;
      metade) f="$(find "$c/_cacache" -type f | head -1)"; command rm -f "$f"; exit 1;;
    esac
    [ -n "$c" ] && command rm -rf "$c/_cacache"; exit 0;;
esac
exit 0
EOF
  chmod +x "$T/bin/npm"
}
duble_pnpm() {
  cat > "$T/bin/pnpm" <<'EOF'
#!/bin/bash
echo "pnpm $*" >> "$DUBLE_CALLS"
case "${DUBLE_PNPM_MODO:-normal}" in
  pede_entrada) read -r _x; exit 1;;
  trava) sleep 1003; exit 1;;
esac
S="${DUBLE_PNPM_STORE:-$HOME/Library/pnpm/store/v11}"
case "$1 ${2:-}" in
  "store path") echo "$S";;
  "store prune") [ "${DUBLE_PNPM_MODO:-normal}" = zero ] && exit 0; command rm -rf "$S/files"; exit 0;;
esac
exit 0
EOF
  chmod +x "$T/bin/pnpm"
}
duble_docker() {
  cat > "$T/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$DUBLE_CALLS"
case "$1" in
  info) case "${DUBLE_DOCKER:-on}" in on) echo ok; exit 0;; trava) sleep 1001; exit 1;; *) exit 1;; esac;;
  context) echo colima;;
  images) for i in ${DUBLE_DOCKER_ORFAS:-}; do echo "$i"; done;;
  system) printf 'sha256:aaa 1.5GB\nsha256:bbb 200MB\nsha256:ccc 3.2GB\n';;
esac
exit 0
EOF
  chmod +x "$T/bin/docker"
}
duble_ollama() {
  cat > "$T/bin/ollama" <<'EOF'
#!/bin/bash
echo "ollama $*" >> "$DUBLE_CALLS"
[ "${DUBLE_OLLAMA:-on}" = trava ] && { sleep 1002; exit 1; }
[ "$1" = list ] && { echo "NAME   ID   SIZE   MODIFIED"; echo "modelo-a:8b   abc123   5.2 GB   3 weeks ago"; }
exit 0
EOF
  chmod +x "$T/bin/ollama"
}
# Processo falso de verdade (não dublê de pgrep): um executável chamado npm/pnpm que dorme.
processo_falso() { # nome args...
  local nome="$1"; shift
  mkdir -p "$T/falsos"
  printf '#!/bin/bash\nsleep 30\n' > "$T/falsos/$nome"; chmod +x "$T/falsos/$nome"
  "$T/falsos/$nome" "$@" 2>/dev/null & FALSO_PID=$!; disown "$FALSO_PID" 2>/dev/null
  sleep 0.3
}
sem_falso() { pkill -P "$FALSO_PID" 2>/dev/null; kill "$FALSO_PID" 2>/dev/null; return 0; }
soma_arvore() { find "$1" \( -path "$1/.mac-optimizer-trash" -o -path "$1/Documents" \) -prune -o -type f -exec stat -f '%N %z %m' {} + 2>/dev/null | sort | cksum; }

novo_ambiente() {
  T="$(mktemp -d -t optimizer-teste)"
  AMBIENTES="$AMBIENTES $T"
  H="$T/home"
  mkdir -p "$H/Library/Caches" "$H/Downloads" "$H/Library/Application Support" "$H/Library/LaunchAgents" \
           "$T/apps" "$T/sys/LaunchAgents" "$T/sys/LaunchDaemons"
  CALLS="$T/calls.log"; : > "$CALLS"
  criar_dubles "$T/bin"
  export HOME="$H" DUBLE_CALLS="$CALLS"
  export OPT_APPS_DIRS="$T/apps" OPT_SYS_AGENT_DIRS="$T/sys/LaunchAgents:$T/sys/LaunchDaemons"
  export OPT_MIN_MB_APPSUPPORT=1
  unset OPT_CACHES OPT_DOWNLOADS OPT_APPSUPPORT OPT_USER_AGENTS OPT_TRASH OPT_LOGDIR OPT_DISK OPT_SESSAO_MAX_MIN
  unset DUBLE_BREW_NADA DUBLE_TM_N DUBLE_PGREP_ABERTO DUBLE_BOOTOUT_FALHA OPT_TRAVA_TENTATIVAS
  unset DUBLE_DISKUTIL DUBLE_NPM_CACHE DUBLE_NPM_MODO DUBLE_NPM_DEVAGAR DUBLE_PNPM_MODO DUBLE_PNPM_STORE \
        DUBLE_DOCKER DUBLE_DOCKER_ORFAS DUBLE_OLLAMA HF_HOME OPT_LIMITE_S OPT_LIMITE_LIMPEZA_S
  export PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  TRASH="$H/.mac-optimizer-trash"
}

roda() { /bin/bash "$SCRIPT" "$@"; }
mb()   { dd if=/dev/zero of="$1" bs=1048576 count="$2" 2>/dev/null; }
sessao_de() { printf '%s\n' "$1" | awk -F'|' '$1=="SESSAO"{print $2}'; }
# ID de um item pelo tipo e nome: id_de "<saida>" INSTALADOR x.dmg
id_de() { printf '%s\n' "$1" | awk -F'|' -v t="$2" -v n="$3" '$1==t && index($0, n){print $2; exit}'; }
# ID de um item da quarentena pelo nome mostrado: qid_de "<saida de listar-quarentena>" nome
qid_de() { printf '%s\n' "$1" | awk -F'|' -v n="$2" '$1=="QITEM" && $5==n{print $2; exit}'; }

criar_app() { # nome bundlename bundleid
  local d="$T/apps/$1.app/Contents"; mkdir -p "$d"
  cat > "$d/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$2</string>
<key>CFBundleIdentifier</key><string>$3</string>
</dict></plist>
EOF
}

criar_agente() { # pasta rotulo programa
  cat > "$1/$2.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$2</string>
<key>ProgramArguments</key><array><string>$3</string></array>
</dict></plist>
EOF
}

conta_arquivos() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "Mac Optimizer — testes (bash $BASH_VERSION)"
echo "Script: $SCRIPT"

# ---------- T01 quarentena nunca sobrescreve ----------
novo_ambiente
mkdir -p "$H/Downloads/a" "$H/Downloads/b"; echo A > "$H/Downloads/a/x.dmg"; echo B > "$H/Downloads/b/x.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
IDS="$(printf '%s\n' "$S" | awk -F'|' '$1=="INSTALADOR"{print $2}' | paste -sd, -)"
roda quarentena --sessao "$SID" --itens "$IDS" >/dev/null
verifica T01 "os dois x.dmg precisam existir na quarentena" \
  test "$(conta_arquivos "$TRASH/$(date +%Y-%m-%d)/dmgs")" = 2
verifica T01b "manifest com 2 linhas" test "$(wc -l < "$TRASH/manifest.tsv" | tr -d ' ')" = 2

# ---------- T02 aprovado = executado ----------
novo_ambiente
echo y > "$H/Downloads/y.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"; IY="$(id_de "$S" INSTALADOR y.dmg)"
echo z > "$H/Downloads/z.dmg"
roda quarentena --sessao "$SID" --itens "$IY" >/dev/null
verifica T02 "só o aprovado é movido; o novo fica" sh -c "[ ! -e '$H/Downloads/y.dmg' ] && [ -e '$H/Downloads/z.dmg' ]"

# ---------- T03 serviço: bootout, sem unload, /Library só instrução ----------
novo_ambiente
criar_agente "$H/Library/LaunchAgents" com.desconhecido.x /usr/bin/true
criar_agente "$T/sys/LaunchDaemons" com.outro.daemon /usr/bin/true
S="$(roda scan)"; SID="$(sessao_de "$S")"; IA="$(id_de "$S" AGENTE com.desconhecido.x)"
echo com.desconhecido.x >> "$T/carregados"
roda remover-agente --sessao "$SID" --itens "$IA" >/dev/null
verifica T03 "bootout chamado para o serviço do usuário" grep -q "launchctl bootout gui/$(id -u) $H/Library/LaunchAgents/com.desconhecido.x.plist" "$CALLS"
verifica T03b "nenhum unload" sh -c "! grep -q 'unload' '$CALLS'"
verifica T03c "serviço de sistema sem ID e sem chamada" sh -c "printf '%s\n' \"\$1\" | grep -q '^AGENTE|-|.*|sistema|com.outro.daemon' && ! grep -q 'com.outro.daemon' '$CALLS'" _ "$S"
verifica T03d "plist foi para a quarentena" test "$(conta_arquivos "$TRASH/$(date +%Y-%m-%d)/launchagents")" = 1

# ---------- T04 nunca chama sudo (fluxo completo) ----------
novo_ambiente
mkdir -p "$H/Library/Caches/AppZ"; mb "$H/Library/Caches/AppZ/f" 1; echo d > "$H/Downloads/w.dmg"
export DUBLE_TM_N=1
S="$(roda scan)"; SID="$(sessao_de "$S")"
roda limpar-caches --sessao "$SID" --itens "$(id_de "$S" CACHE AppZ)" >/dev/null
roda limpar-brew-pip --sessao "$SID" >/dev/null
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR w.dmg)" >/dev/null
roda concluir --sessao "$SID" >/dev/null
verifica T04 "sudo nunca chamado" sh -c "! grep -q '^sudo' '$CALLS'"

# ---------- T05 caches: exclusões, protegido, app aberto ----------
novo_ambiente
for c in ms-playwright Homebrew pip com.apple.x AppX; do mkdir -p "$H/Library/Caches/$c"; mb "$H/Library/Caches/$c/f" 1; done
chmod 555 "$H/Library/Caches/com.apple.x"
export DUBLE_PGREP_ABERTO=AppX
S="$(roda scan)"; SID="$(sessao_de "$S")"
verifica T05 "só AppX listado para apagar" test "$(printf '%s\n' "$S" | grep -c '^CACHE|')" = 1
verifica T05b "AppX com aviso de app aberto" sh -c "printf '%s\n' \"\$1\" | grep -q '^CACHE|C1|AppX|1|volta_sozinho|app_aberto'" _ "$S"
verifica T05c "4 mantidos com motivo" test "$(printf '%s\n' "$S" | grep -c '^CACHE_MANTIDO|')" = 4
verifica T05d "protegido não entra na soma" sh -c "printf '%s\n' \"\$1\" | grep -q '^CACHE_TOTAL|1$'" _ "$S"

# ---------- T06 Application Support ----------
novo_ambiente
criar_app "Visual Studio Code" Code com.microsoft.VSCode
for d in com.apple.algo Codex Code SemDono; do mkdir -p "$H/Library/Application Support/$d"; mb "$H/Library/Application Support/$d/f" 2; done
S="$(roda previa)"
verifica T06 "só SemDono como talvez órfão" sh -c "[ \"\$(printf '%s\n' \"\$1\" | grep '^APPSUPPORT|' | cut -d'|' -f3)\" = SemDono ]" _ "$S"

# ---------- T07 classificação de serviços ----------
novo_ambiente
criar_app "Google Chrome" "Google Chrome" com.google.Chrome
mkdir -p "$H/bin"
criar_agente "$H/Library/LaunchAgents" com.exemplo.bot "$H/bin/bot.sh"
criar_agente "$H/Library/LaunchAgents" homebrew.mxcl.redis /usr/bin/true
criar_agente "$H/Library/LaunchAgents" com.google.keystone.agent /usr/bin/true
criar_agente "$H/Library/LaunchAgents" com.desconhecido.x /usr/bin/true
# programa do Homebrew rodando um script da pasta do usuário → usuário
cat > "$H/Library/LaunchAgents/com.exemplo.py.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.exemplo.py</string>
<key>ProgramArguments</key><array><string>/opt/homebrew/bin/python3</string><string>$H/bin/tarefa.py</string></array>
</dict></plist>
EOF
# updater de app instalado com programa dentro da pasta do usuário → app instalado
criar_agente "$H/Library/LaunchAgents" com.google.updater.wake "$H/Library/Application Support/Google/updater"
S="$(roda previa)"
classe_de() { printf '%s\n' "$S" | awk -F'|' -v l="$1" '$1=="AGENTE" && $5==l{print $3}'; }
verifica T07 "usuário / homebrew / app instalado / desconhecido" sh -c \
  "[ '$(classe_de com.exemplo.bot)' = usuario ] && [ '$(classe_de homebrew.mxcl.redis)' = homebrew ] && [ '$(classe_de com.google.keystone.agent)' = app_instalado ] && [ '$(classe_de com.desconhecido.x)' = desconhecido ]"
verifica T07b "python do Homebrew com script do usuário = usuário; updater de app = app instalado" sh -c \
  "[ '$(classe_de com.exemplo.py)' = usuario ] && [ '$(classe_de com.google.updater.wake)' = app_instalado ]"

# ---------- T06b pasta genérica com conteúdo de app instalado ----------
novo_ambiente
criar_app "Notas Exemplo" "Notas Exemplo" com.exemplo.notas
mkdir -p "$H/Library/Application Support/Caches/notasexemplo-updater"; mb "$H/Library/Application Support/Caches/notasexemplo-updater/f" 2
mkdir -p "$H/Library/Application Support/Caches2/semapp-x"; mb "$H/Library/Application Support/Caches2/semapp-x/f" 2
S="$(roda previa)"
verifica T06b "Caches com updater de app instalado não é órfã; Caches2 é" sh -c \
  "[ \"\$(printf '%s\n' \"\$1\" | grep '^APPSUPPORT|' | cut -d'|' -f3)\" = Caches2 ]" _ "$S"

# ---------- T08 alias de ls não muda nada ----------
novo_ambiente
echo q > "$H/Downloads/q.dmg"
A1="$(roda previa | grep -E '^(INSTALADOR|CACHE_TOTAL|APPSUPPORT_TOTAL)')"
A2="$(zsh -f -c "alias ls='ls -lah'; /bin/bash '$SCRIPT' previa" | grep -E '^(INSTALADOR|CACHE_TOTAL|APPSUPPORT_TOTAL)')"
verifica T08 "saída igual com alias ls" test "$A1" = "$A2"

# ---------- T09 log grava em processos separados ----------
novo_ambiente
echo l > "$H/Downloads/l.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR l.dmg)" >/dev/null
LOGF="$H/Documents/Mac Optimizer/logs/$SID.log"
verifica T09 "log tem scan e ação" sh -c "grep -q 'SCAN iniciado' '$LOGF' && grep -q 'QUARENTENA' '$LOGF'"

# ---------- T10 disco certo ----------
verifica T10 "df chamado com o volume de dados" grep -q "^df -k /System/Volumes/Data" "$CALLS"

# ---------- T11 snapshots ----------
novo_ambiente; export DUBLE_TM_N=0
verifica T11 "0 snapshots com só o cabeçalho" sh -c "/bin/bash '$SCRIPT' previa | grep -q '^SNAPSHOTS|0$'"
export DUBLE_TM_N=2
verifica T11b "2 snapshots" sh -c "/bin/bash '$SCRIPT' previa | grep -q '^SNAPSHOTS|2$'"
verifica T11c "skill não promete GB de snapshot" sh -c "! grep -iE 'snapshot[^|]*[0-9X]+[.,]?[0-9X]*GB' '$SKILL'"

# ---------- T12 relatório separa apagado e quarentena ----------
novo_ambiente
mb "$H/Downloads/grande.dmg" 5; mkdir -p "$H/Library/Caches/AppC"; mb "$H/Library/Caches/AppC/f" 3
S="$(roda scan)"; SID="$(sessao_de "$S")"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR grande.dmg)" >/dev/null
roda limpar-caches --sessao "$SID" --itens "$(id_de "$S" CACHE AppC)" >/dev/null
R="$(roda concluir --sessao "$SID")"
verifica T12 "apagado 3 MB e quarentena 5 MB" sh -c "printf '%s\n' \"\$1\" | grep -q '^RELATORIO|apagado_mb=3|.*|quarentena_mb=5$'" _ "$R"

# ---------- T13 sem dupla contagem ----------
novo_ambiente
mkdir -p "$H/Library/Caches/Homebrew" "$H/Library/Caches/pip" "$H/Library/Caches/Outro"
mb "$H/Library/Caches/Homebrew/f" 2; mb "$H/Library/Caches/pip/f" 1; mb "$H/Library/Caches/Outro/f" 1
verifica T13 "total de caches só com Outro" sh -c "/bin/bash '$SCRIPT' previa | grep -q '^CACHE_TOTAL|1$'"

# ---------- T14 nomes com espaço ----------
novo_ambiente
mkdir -p "$H/Library/Caches/Pasta Com Espaco"; mb "$H/Library/Caches/Pasta Com Espaco/f" 1
echo e > "$H/Downloads/Arquivo Com Espaco.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
verifica T14 "nome inteiro na saída" sh -c "printf '%s\n' \"\$1\" | grep -q '|Pasta Com Espaco|' && printf '%s\n' \"\$1\" | grep -q '|Arquivo Com Espaco.dmg|'" _ "$S"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR 'Arquivo Com Espaco.dmg')" >/dev/null
roda limpar-caches --sessao "$SID" --itens "$(id_de "$S" CACHE 'Pasta Com Espaco')" >/dev/null
verifica T14b "ação com nome inteiro" sh -c "ls '$TRASH/$(date +%Y-%m-%d)/dmgs/' | grep -q 'Arquivo Com Espaco.dmg' && [ ! -e '$H/Library/Caches/Pasta Com Espaco' ]"

# ---------- T15 brew: nada × não instalado ----------
novo_ambiente; export DUBLE_BREW_NADA=1
verifica T15 "brew sem nada a limpar = nada" sh -c "/bin/bash '$SCRIPT' previa | grep -q '^BREW|nada$'"
mkdir -p "$T/bin2"; cp "$T/bin/"* "$T/bin2/"; command rm -f "$T/bin2/brew"
verifica T15b "sem brew = não instalado" sh -c "PATH='$T/bin2:/usr/bin:/bin:/usr/sbin:/sbin' /bin/bash '$SCRIPT' previa | grep -q '^BREW|nao_instalado$'"

# ---------- T16 Downloads sem permissão ----------
novo_ambiente
chmod 000 "$H/Downloads"
verifica T16 "aviso de permissão" sh -c "/bin/bash '$SCRIPT' previa | grep -q '^AVISO|downloads_sem_permissao|'"
chmod 755 "$H/Downloads"

# ---------- T17–T19 textos ----------
verifica T17 "sem '7 dias'; com '30 dias'" sh -c "! grep -q '7 dias' '$SKILL' '$SCRIPT' && grep -q '30 dias' '$SKILL'"
verifica T18 "sem [s/n] e sem [s] manter/remover" sh -c "! grep -qE '\[s/n\]|\[s\] (manter|remover)' '$SKILL'"
verifica T19 "sem '95%' e sem contador de tokens" sh -c "! grep -qiE '95%|tokens desta sess' '$SKILL' '$SCRIPT'"

# ---------- T20 idade pela data da quarentena; log sem nome ----------
novo_ambiente
echo v > "$H/Downloads/nomeunico-abc.dmg"; touch -t 202601010000 "$H/Downloads/nomeunico-abc.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR nomeunico-abc.dmg)" >/dev/null
L="$(roda listar-quarentena)"
verifica T20 "listagem por item com 0 dias" sh -c "printf '%s\n' \"\$1\" | grep -q '^QITEM|Q1|novo|dmgs|nomeunico-abc.dmg|0|0$'" _ "$L"
verifica T20b "log sem o nome do arquivo" sh -c "! grep -q 'nomeunico' '$H/Documents/Mac Optimizer/logs/$SID.log'"

# ---------- T-PREV prévia nunca mexe ----------
novo_ambiente
echo p > "$H/Downloads/p.dmg"; mkdir -p "$H/Library/Caches/AppP"; mb "$H/Library/Caches/AppP/f" 1
assinatura() { find "$H/Downloads" "$H/Library" -exec stat -f '%N %z %m' {} + | sort | md5; }
ANTES="$(assinatura)"
S="$(roda previa)"; SID="$(sessao_de "$S")"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR p.dmg)" >/dev/null; C1=$?
roda limpar-caches --sessao "$SID" --itens "$(id_de "$S" CACHE AppP)" >/dev/null; C2=$?
roda limpar-brew-pip --sessao "$SID" >/dev/null; C3=$?
verifica T-PREV "ações recusadas (código 7)" test "$C1$C2$C3" = 777
verifica T-PREVb "nada mudou nas pastas" test "$ANTES" = "$(assinatura)"

# ---------- T-RST restaurar ----------
novo_ambiente
echo r1 > "$H/Downloads/r1.dmg"; echo r2 > "$H/Downloads/r2.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR r1.dmg),$(id_de "$S" INSTALADOR r2.dmg)" >/dev/null
roda restaurar Q1 >/dev/null
verifica T-RST "voltou ao lugar e sobrou 1 na quarentena" sh -c "[ -e '$H/Downloads/r1.dmg' ] && /bin/bash '$SCRIPT' listar-quarentena | grep -q '^QUARENTENA_ITENS|1$'"

# ---------- T-RST-OCUP restaurar com destino ocupado ----------
novo_ambiente
echo antigo > "$H/Downloads/o.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR o.dmg)" >/dev/null
echo novo > "$H/Downloads/o.dmg"
OUT="$(roda restaurar Q1)"; C=$?
verifica T-RST-OCUP "recusa e não sobrescreve" sh -c "[ $C = 4 ] && [ \"\$(cat '$H/Downloads/o.dmg')\" = novo ] && printf '%s' \"\$1\" | grep -q destino_ocupado && /bin/bash '$SCRIPT' listar-quarentena | grep -q '^QUARENTENA_ITENS|1$'" _ "$OUT"

# ---------- T-RST-AG restaurar serviço religa ----------
novo_ambiente
criar_agente "$H/Library/LaunchAgents" com.desconhecido.y /usr/bin/true
S="$(roda scan)"; SID="$(sessao_de "$S")"
roda remover-agente --sessao "$SID" --itens "$(id_de "$S" AGENTE com.desconhecido.y)" >/dev/null
roda restaurar Q1 >/dev/null
verifica T-RST-AG "bootstrap chamado" grep -q "launchctl bootstrap gui/$(id -u) $H/Library/LaunchAgents/com.desconhecido.y.plist" "$CALLS"

# ---------- T-ANT quarentena no formato antigo ----------
novo_ambiente
mkdir -p "$TRASH/2026-01-05/dmgs"; echo velho > "$TRASH/2026-01-05/dmgs/velho.dmg"
L="$(roda listar-quarentena)"
verifica T-ANT "listado como antigo, com dias > 0" sh -c "printf '%s\n' \"\$1\" | awk -F'|' '\$1==\"QITEM\" && \$3==\"antigo\" && \$5==\"velho.dmg\" && \$7>0{f=1} END{exit !f}'" _ "$L"
QV="$(qid_de "$L" velho.dmg)"
roda restaurar "$QV" >/dev/null; C=$?
verifica T-ANTb "sem destino pede destino (código 3)" test "$C" = 3
roda restaurar "$QV" --destino "$H/Downloads/velho.dmg" >/dev/null
verifica T-ANTc "restaurado no destino escolhido" test -e "$H/Downloads/velho.dmg"

# ---------- T-PIPE nome com "|" na quarentena ----------
novo_ambiente
mkdir -p "$TRASH/2026-01-05/dmgs"
echo a > "$TRASH/2026-01-05/dmgs/a|b.dmg"; echo c > "$TRASH/2026-01-05/dmgs/c|d.dmg"; echo n > "$TRASH/2026-01-05/dmgs/normal.dmg"
OUT="$(roda previa 2>&1)"; C=$?
verifica T-PIPE "prévia termina e conta os 3 itens" sh -c "[ $C = 0 ] && printf '%s\n' \"\$1\" | grep -q '^QUARENTENA|3|'" _ "$OUT"
L="$(roda listar-quarentena)"
verifica T-PIPEb "listagem com 7 campos e nome legível" sh -c \
  "printf '%s\n' \"\$1\" | awk -F'|' '\$1==\"QITEM\"{n++; if (NF!=7) e=1} END{exit !(n==3 && !e)}' && printf '%s\n' \"\$1\" | grep -q '|a¦b.dmg|'" _ "$L"
QA="$(qid_de "$L" 'a¦b.dmg')"; QC="$(qid_de "$L" 'c¦d.dmg')"
verifica T-PIPEc "ID estável entre duas listagens" test -n "$QA" -a "$QA" = "$(qid_de "$(roda listar-quarentena)" 'a¦b.dmg')"
roda restaurar "$QA" --destino "$H/Downloads/a|b.dmg" >/dev/null
verifica T-PIPEd "restaurado com o nome verdadeiro" sh -c "[ -e '$H/Downloads/a|b.dmg' ] && [ ! -e '$TRASH/2026-01-05/dmgs/a|b.dmg' ]"
roda apagar-de-vez "$QC" >/dev/null
verifica T-PIPEe "apagado de vez (item com mais de 30 dias)" sh -c "[ ! -e '$TRASH/2026-01-05/dmgs/c|d.dmg' ] && [ -e '$TRASH/2026-01-05/dmgs/normal.dmg' ]"
novo_ambiente
echo x > "$H/Downloads/x|y.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
verifica T-PIPEf "linha do scan com 5 campos" sh -c "printf '%s\n' \"\$1\" | awk -F'|' '\$1==\"INSTALADOR\" && NF==5 && \$4==\"x¦y.dmg\"{f=1} END{exit !f}'" _ "$S"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR 'x¦y.dmg')" >/dev/null
roda restaurar Q1 >/dev/null
verifica T-PIPEg "item novo com | volta ao lugar" sh -c "[ -e '$H/Downloads/x|y.dmg' ] && /bin/bash '$SCRIPT' listar-quarentena | grep -q '^QUARENTENA_ITENS|0$'"

# ---------- T-PRAZO apagar de vez antes dos 30 dias ----------
novo_ambiente
echo z > "$H/Downloads/z.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR z.dmg)" >/dev/null
QZ="$(awk -F'\t' '{print $5}' "$TRASH/manifest.tsv")"
OUT="$(roda apagar-de-vez Q1)"; C=$?
verifica T-PRAZO "recusa por padrão (código 10) e o arquivo fica" sh -c "[ $C = 10 ] && printf '%s' \"\$1\" | grep -q 'antes_do_prazo' && [ -e '$QZ' ]" _ "$OUT"
OUT="$(roda apagar-de-vez Q1 --antes-do-prazo)"; C=$?
verifica T-PRAZOb "com confirmação expressa apaga" sh -c "[ $C = 0 ] && printf '%s' \"\$1\" | grep -q '^APAGADO_DE_VEZ|Q1|' && [ ! -e '$QZ' ]" _ "$OUT"
verifica T-PRAZOc "skill só usa a opção a pedido expresso" sh -c "grep -q -- '--antes-do-prazo' '$SKILL' && grep -qi 'com todas as letras' '$SKILL'"

# ---------- T-TAB nome com TAB na quarentena ----------
novo_ambiente
D="$TRASH/2026-01-05/dmgs"; mkdir -p "$D"
NT="$(printf 'a\tb.dmg')"; echo a > "$D/$NT"; NT2="$(printf 'c\td.dmg')"; echo c > "$D/$NT2"
OUT="$(roda previa 2>&1)"; C=$?
verifica T-TAB "prévia termina, sem erro, conta 2 itens" sh -c "[ $C = 0 ] && ! printf '%s\n' \"\$1\" | grep -q 'line [0-9]' && printf '%s\n' \"\$1\" | grep -q '^QUARENTENA|2|'" _ "$OUT"
L="$(roda listar-quarentena)"
verifica T-TABb "listagem com 7 campos, nome inteiro, dias certos" sh -c \
  "printf '%s\n' \"\$1\" | awk -F'|' '\$1==\"QITEM\"{n++; if (NF!=7 || \$7<30) e=1} END{exit !(n==2 && !e)}' && printf '%s\n' \"\$1\" | grep -q '|a b.dmg|'" _ "$L"
roda restaurar "$(qid_de "$L" 'a b.dmg')" --destino "$H/Downloads/$NT" >/dev/null
verifica T-TABc "restaurado com o nome verdadeiro" sh -c "[ -e \"\$1\" ] && [ ! -e \"\$2\" ]" _ "$H/Downloads/$NT" "$D/$NT"
roda apagar-de-vez "$(qid_de "$L" 'c d.dmg')" >/dev/null
verifica T-TABd "apagado de vez" test ! -e "$D/$NT2"

# ---------- T-NL quebra de linha no nome ----------
novo_ambiente
D="$TRASH/2026-01-05/dmgs"; mkdir -p "$D"
NL="$(printf 'c\nd.dmg')"; echo c > "$D/$NL"; echo isca > "$D/c d.dmg"
OUT="$(roda previa 2>&1)"; C=$?
verifica T-NL "prévia termina sem erro e conta 2 itens" sh -c "[ $C = 0 ] && ! printf '%s\n' \"\$1\" | grep -qi 'line [0-9]\|awk:' && printf '%s\n' \"\$1\" | grep -q '^QUARENTENA|2|'" _ "$OUT"
L="$(roda listar-quarentena)"
QN="$(printf '%s\n' "$L" | awk -F'|' '$1=="QITEM" && $3=="nome_invalido"{print $2}')"
verifica T-NLb "listado como nome_invalido, 7 campos" sh -c "[ -n '$QN' ] && printf '%s\n' \"\$1\" | awk -F'|' '\$1==\"QITEM\" && NF!=7{e=1} END{exit e}'" _ "$L"
OUT="$(roda restaurar "$QN" --destino "$H/Downloads/x.dmg")"; C1=$?
OUT2="$(roda apagar-de-vez "$QN" --antes-do-prazo)"; C2=$?
verifica T-NLc "restaurar e apagar recusam (código 11), dizem a pasta e nada muda" sh -c \
  "[ $C1$C2 = 1111 ] && printf '%s' \"\$1\" | grep -q 'nome_invalido|pasta=$D|renomear_no_finder' && [ -e \"\$2\" ] && [ -e '$D/c d.dmg' ] && [ ! -e '$H/Downloads/x.dmg' ]" _ "$OUT$OUT2" "$D/$NL"
mv "$D/$NL" "$D/cd.dmg"
L="$(roda listar-quarentena)"
roda apagar-de-vez "$(qid_de "$L" cd.dmg)" >/dev/null
verifica T-NLd "depois de renomeado volta a funcionar" sh -c "printf '%s\n' \"\$1\" | grep -q '|antigo|dmgs|cd.dmg|' && [ ! -e '$D/cd.dmg' ]" _ "$L"
novo_ambiente
NL="$(printf 'e\nf.dmg')"; echo e > "$H/Downloads/$NL"
mkdir -p "$H/Library/Application Support/$(printf 'g\nh')"; mb "$H/Library/Application Support/$(printf 'g\nh')/f" 2
S="$(roda scan 2>&1)"; C=$?; SID="$(sessao_de "$S")"
verifica T-NLe "scan sem erro; recusa pôr na quarentena e diz a pasta" sh -c \
  "[ $C = 0 ] && ! printf '%s\n' \"\$1\" | grep -qi 'line [0-9]\|awk:' && printf '%s\n' \"\$1\" | grep -q '^NOME_INVALIDO|dmgs|e f.dmg|[0-9.]*|$H/Downloads$' && printf '%s\n' \"\$1\" | grep -q '^NOME_INVALIDO|appsupport|g h|' && ! printf '%s\n' \"\$1\" | grep -q '^INSTALADOR|I'" _ "$S"
OUT="$(roda quarentena --sessao "$SID" --itens I1)"
verifica T-NLf "nada entra na quarentena" sh -c "[ -e \"\$1\" ] && [ ! -e '$TRASH/manifest.tsv' ]" _ "$H/Downloads/$NL"
verifica T-NLg "skill explica nome inválido e Finder" sh -c "grep -q 'NOME_INVALIDO' '$SKILL' && grep -q 'nome_invalido' '$SKILL' && grep -qi 'Finder' '$SKILL'"

# ---------- T-TABSCAN TAB no nome nunca entra na sessão (achado do Codex) ----------
novo_ambiente
mkdir -p "$H/Library/Caches/Keep"; echo importante > "$H/Library/Caches/Keep/dado"
IK="$(stat -f %i "$H/Library/Caches/Keep")"; mkdir "$H/Library/Caches/$(printf 'Keep\t0\t0\t%s' "$IK")"
echo t > "$H/Downloads/$(printf 'a\tb.dmg')"
S="$(roda scan 2>&1)"; SID="$(sessao_de "$S")"
verifica T-TABSCAN "nome com TAB vira NOME_INVALIDO (cache e instalador)" sh -c \
  "printf '%s\n' \"\$1\" | grep -q '^NOME_INVALIDO|cache|Keep 0 0 ' && printf '%s\n' \"\$1\" | grep -q '^NOME_INVALIDO|dmgs|a b.dmg|' && [ \"\$(printf '%s\n' \"\$1\" | grep -c '^CACHE|C')\" = 1 ] && ! printf '%s\n' \"\$1\" | grep -q '^INSTALADOR|I'" _ "$S"
roda limpar-caches --sessao "$SID" --itens C2 >/dev/null
verifica T-TABSCANb "aprovar ID inexistente não apaga a vizinha" test -e "$H/Library/Caches/Keep/dado"

# ---------- T-LOCK número da quarentena nunca repete (achado do Codex) ----------
novo_ambiente
echo l > "$H/Downloads/l.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
mkdir -p "$TRASH/.trava"; echo $$ > "$TRASH/.trava/pid"
OUT="$(OPT_TRAVA_TENTATIVAS=3 roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR l.dmg)")"
verifica T-LOCK "trava ocupada: recusa e não move" sh -c "printf '%s' \"\$1\" | grep -q 'ocupado' && [ -e '$H/Downloads/l.dmg' ]" _ "$OUT"
echo 999999 > "$TRASH/.trava/pid"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR l.dmg)" >/dev/null
verifica T-LOCKb "trava abandonada é liberada e some no fim" sh -c "[ ! -e '$H/Downloads/l.dmg' ] && [ ! -e '$TRASH/.trava' ]"
novo_ambiente
i=0; while [ $i -lt 6 ]; do i=$((i+1)); echo $i > "$H/Downloads/p$i.dmg"; done
S="$(roda scan)"; SID="$(sessao_de "$S")"
for i in 1 2 3 4 5 6; do roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR "p$i.dmg")" >/dev/null & done; wait
verifica T-LOCKc "6 ao mesmo tempo: 6 números diferentes" sh -c "[ \"\$(cut -f1 '$TRASH/manifest.tsv' | sort -u | wc -l | tr -d ' ')\" = 6 ] && [ \"\$(wc -l < '$TRASH/manifest.tsv' | tr -d ' ')\" = 6 ]"

# ---------- T-MANIF falha ao gravar o registro (achado do Codex) ----------
novo_ambiente
echo m1 > "$H/Downloads/m1.dmg"; echo m2 > "$H/Downloads/m2.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR m1.dmg)" >/dev/null
chmod 444 "$TRASH/manifest.tsv"
OUT="$(roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR m2.dmg)")"
chmod 644 "$TRASH/manifest.tsv"
verifica T-MANIF "não diz movido; item volta para o lugar" sh -c "printf '%s' \"\$1\" | grep -q 'registro_nao_gravou' && ! printf '%s' \"\$1\" | grep -q '^MOVIDO' && [ -e '$H/Downloads/m2.dmg' ]" _ "$OUT"

# ---------- T-BOOT serviço que não desligou (achado do Codex) ----------
novo_ambiente
criar_agente "$H/Library/LaunchAgents" com.desconhecido.b /usr/bin/true
S="$(roda scan)"; SID="$(sessao_de "$S")"; IB="$(id_de "$S" AGENTE com.desconhecido.b)"
echo com.desconhecido.b >> "$T/carregados"
OUT="$(DUBLE_BOOTOUT_FALHA=1 roda remover-agente --sessao "$SID" --itens "$IB")"
verifica T-BOOT "falhou ao desligar: recusa e não move" sh -c "printf '%s' \"\$1\" | grep -q 'nao_desligou' && [ -e '$H/Library/LaunchAgents/com.desconhecido.b.plist' ]" _ "$OUT"
OUT="$(roda remover-agente --sessao "$SID" --itens "$IB")"
verifica T-BOOTb "desligou: move e diz desligado" sh -c "printf '%s' \"\$1\" | grep -q '^SERVICO_DESLIGADO' && [ ! -e '$H/Library/LaunchAgents/com.desconhecido.b.plist' ]" _ "$OUT"
novo_ambiente
criar_agente "$H/Library/LaunchAgents" com.desconhecido.c /usr/bin/true
S="$(roda scan)"; SID="$(sessao_de "$S")"
OUT="$(roda remover-agente --sessao "$SID" --itens "$(id_de "$S" AGENTE com.desconhecido.c)")"
verifica T-BOOTc "já desligado: move sem chamar bootout" sh -c "printf '%s' \"\$1\" | grep -q '^SERVICO_DESLIGADO' && ! grep -q 'bootout' '$CALLS'" _ "$OUT"

# ---------- T-AWK sem aviso solto na listagem ----------
novo_ambiente
echo w > "$H/Downloads/w.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR w.dmg)" >/dev/null
mkdir -p "$TRASH/2026-01-05/dmgs"; echo n > "$TRASH/2026-01-05/dmgs/$(printf 'x\ny.dmg')"
ERR="$(roda listar-quarentena 2>&1 >/dev/null)"
verifica T-AWK "listagem sem aviso na saída de erro" test -z "$ERR"
verifica T-SKILL2 "skill explica nao_desligou, ocupado e TAB" sh -c "grep -q 'nao_desligou' '$SKILL' && grep -q 'ocupado' '$SKILL' && grep -qi 'tabula' '$SKILL'"

# ---------- T-SES sessões ----------
novo_ambiente
echo s1 > "$H/Downloads/s1.dmg"
SA="$(sessao_de "$(roda scan)")"
echo s2 > "$H/Downloads/s2.dmg"
SBOUT="$(roda scan)"; IB="$(id_de "$SBOUT" INSTALADOR s2.dmg)"
OUT="$(roda quarentena --sessao "$SA" --itens "$IB")"
verifica T-SES1 "ID de item de outra sessão recusado" sh -c "printf '%s' \"\$1\" | grep -q 'item_inexistente_na_sessao' && [ -e '$H/Downloads/s2.dmg' ]" _ "$OUT"
roda quarentena --sessao "20990101-000000-1" --itens I1 >/dev/null; C=$?
verifica T-SES1b "sessão inventada recusada (código 5)" test "$C" = 5
novo_ambiente
echo m > "$H/Downloads/m.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
mb "$H/Downloads/m.dmg" 1
OUT="$(roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR m.dmg)")"
verifica T-SES2 "item que mudou é recusado" sh -c "printf '%s' \"\$1\" | grep -q 'item_mudou' && [ -e '$H/Downloads/m.dmg' ]" _ "$OUT"
novo_ambiente
echo v > "$H/Downloads/v.dmg"
S="$(roda scan)"; SID="$(sessao_de "$S")"
SFILE="$TRASH/.sessoes/$SID.tsv"
awk -F'\t' -v t="$(( $(date +%s) - 7200 ))" 'BEGIN{OFS="\t"} $1=="#criado"{$2=t} {print}' "$SFILE" > "$SFILE.x" && mv "$SFILE.x" "$SFILE"
roda quarentena --sessao "$SID" --itens "$(id_de "$S" INSTALADOR v.dmg)" >/dev/null; C=$?
verifica T-SES3 "sessão de 2 h recusada (código 6)" test "$C" = 6

# ---------- T-SESCLEAN ----------
verifica T-SESCLEAN "vencida apagada no próximo scan" sh -c "/bin/bash '$SCRIPT' previa >/dev/null; [ ! -e '$SFILE' ]"
S="$(roda previa)"; SID="$(sessao_de "$S")"; roda concluir --sessao "$SID" >/dev/null
verifica T-SESCLEANb "concluída apagada" test ! -e "$TRASH/.sessoes/$SID.tsv"
verifica T-SESCLEANc "listagem ignora .sessoes" sh -c "! /bin/bash '$SCRIPT' listar-quarentena | grep -q 'sessoes'"

# ---------- T-ROOT trava de raiz ----------
novo_ambiente
mkdir -p "$H/Library/Caches/AppR"; mb "$H/Library/Caches/AppR/f" 1
S="$(roda scan)"; SID="$(sessao_de "$S")"; IC="$(id_de "$S" CACHE AppR)"
OPT_CACHES="" /bin/bash "$SCRIPT" limpar-caches --sessao "$SID" --itens "$IC" >/dev/null; C1=$?
OPT_TRASH="/" /bin/bash "$SCRIPT" quarentena --sessao "$SID" --itens I1 >/dev/null; C2=$?
OPT_CACHES="$H" /bin/bash "$SCRIPT" limpar-caches --sessao "$SID" --itens "$IC" >/dev/null; C3=$?
verifica T-ROOT "recusa raiz vazia, / e HOME (código 9) e nada apagado" sh -c "[ '$C1$C2$C3' = 999 ] && [ -e '$H/Library/Caches/AppR/f' ]"

# ---------- T-INST instalador local ----------
novo_ambiente
mkdir -p "$H/.claude/commands"; echo antigo > "$H/.claude/commands/optimizer.md"
/bin/bash "$REPO/install.sh" >/dev/null 2>&1
verifica T-INST "pasta instalada, comando antigo removido, script roda" sh -c \
  "[ -f '$H/.claude/skills/optimizer/SKILL.md' ] && [ -f '$H/.claude/skills/optimizer/scripts/optimizer.sh' ] && [ ! -e '$H/.claude/commands/optimizer.md' ] && /bin/bash '$H/.claude/skills/optimizer/scripts/optimizer.sh' versao | grep -q '^VERSAO|'"

# ---------- T-AVISO / T-LINHA / T-DMI / T-GUARDA ----------
verifica T-AVISO "optimizer.md antigo é só aviso" sh -c "! grep -q '\`\`\`bash' '$REPO/optimizer.md' && grep -qF -- \"\$1\" '$REPO/optimizer.md'" _ "$LINHA_INSTALACAO"
verifica T-LINHA "linha idêntica nos 4 lugares" sh -c "for f in README.md TUTORIAL.md index.html optimizer.md; do grep -qF -- \"\$1\" '$REPO/'\$f || exit 1; done" _ "$LINHA_INSTALACAO"
verifica T-DMI "disable-model-invocation e chamadas com bash" sh -c \
  "grep -q '^disable-model-invocation: true$' '$SKILL' && ! grep 'optimizer.sh' '$SKILL' | grep -v 'curl -fsSL' | grep -vqF 'bash \"\${CLAUDE_SKILL_DIR}/scripts/optimizer.sh\"'"
V_SCRIPT="$(/bin/bash "$SCRIPT" versao | cut -d'|' -f2)"
verifica T-GUARDA "skill confere versão e proíbe limpar fora do script" sh -c \
  "grep -qi 'versão esperada: $V_SCRIPT' '$SKILL' && grep -qi 'nunca execute limpeza fora do script' '$SKILL' && grep -qi 'reinstal' '$SKILL'"

# ====================== Fase 2 (2.1.0) ======================
linha_de() { printf '%s\n' "$1" | grep -F -- "$2" | head -1; }

# ---------- T-NPM ----------
novo_ambiente; duble_npm
mkdir -p "$H/.npm/_cacache/x"; mb "$H/.npm/_cacache/x/f" 3
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
verifica T-NPM "scan mostra o cache do npm com ID e 3 MB" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|D[0-9]*|npm_cache|3|volta_sozinho'" _ "$S"
OUT="$(roda limpar-dev --sessao "$SID" --itens "$ID")"
HR="$(cd -P "$H" && pwd -P)"   # caminho real (no macOS /var é link para /private/var)
verifica T-NPMb "chama npm cache clean com a pasta-mãe e o cache esvazia" sh -c \
  "grep -qxF -- 'npm cache clean --force --cache $HR/.npm' '$CALLS' && [ ! -e '$H/.npm/_cacache' ] && printf '%s' \"\$1\" | grep -q '^LIBERADO|$ID|3'" _ "$OUT"
novo_ambiente; duble_npm
mkdir -p "$H/.npm/_cacache"; mb "$H/.npm/_cacache/f" 2
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
OUT="$(DUBLE_NPM_MODO=nao_apaga roda limpar-dev --sessao "$SID" --itens "$ID")"
verifica T-NPMc "npm que não apaga nada = falha, não sucesso" sh -c "printf '%s' \"\$1\" | grep -q '^FALHOU|$ID|nada_liberado' && ! printf '%s' \"\$1\" | grep -q '^LIBERADO'" _ "$OUT"

# ---------- T-NPM-CACHE ----------
novo_ambiente; duble_npm
mkdir -p "$H/.npm/_cacache" "$H/trabalho" "$H/outro/_cacache"; mb "$H/.npm/_cacache/f" 1; mb "$H/outro/_cacache/g" 1
echo "cache=$H/outro" > "$H/trabalho/.npmrc"
S="$(cd "$H/trabalho" && roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
(cd "$H/trabalho" && roda limpar-dev --sessao "$SID" --itens "$ID" >/dev/null)
verifica T-NPM-CACHE ".npmrc de outra pasta não muda o cache limpo" sh -c "[ ! -e '$H/.npm/_cacache' ] && [ -e '$H/outro/_cacache/g' ]"
novo_ambiente
mkdir -p "$H/.npm/_cacache"; mb "$H/.npm/_cacache/f" 2
S="$(roda scan)"
verifica T-NPM-CACHEb "npm fora do PATH com cache presente: tamanho sem ID" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|-|npm_cache|2|npm_fora_do_path'" _ "$S"

# ---------- T-NPM-INSTALANDO / T-NPM-EXEC (processo falso de verdade) ----------
novo_ambiente; duble_npm
mkdir -p "$H/.npm/_cacache"; mb "$H/.npm/_cacache/f" 1
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
processo_falso npm install lodash
OUT="$(roda limpar-dev --sessao "$SID" --itens "$ID")"; sem_falso
verifica T-NPM-INSTALANDO "npm install rodando: recusa e não chama o clean" sh -c "printf '%s' \"\$1\" | grep -q 'instalacao_em_andamento' && ! grep -q 'cache clean' '$CALLS' && [ -e '$H/.npm/_cacache/f' ]" _ "$OUT"
processo_falso npm exec @algum/servidor-mcp
OUT="$(roda limpar-dev --sessao "$SID" --itens "$ID")"; sem_falso
verifica T-NPM-EXEC "npm exec rodando não bloqueia" sh -c "printf '%s' \"\$1\" | grep -q '^LIBERADO|$ID'" _ "$OUT"
novo_ambiente; duble_npm
mkdir -p "$H/.npm/_cacache"; mb "$H/.npm/_cacache/f" 1
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
processo_falso npx algo
OUT="$(roda limpar-dev --sessao "$SID" --itens "$ID")"; sem_falso
verifica T-NPM-EXECb "npx rodando não bloqueia" sh -c "printf '%s' \"\$1\" | grep -q '^LIBERADO|$ID'" _ "$OUT"

# ---------- T-PNPM ----------
novo_ambiente; duble_pnpm
P="$H/Library/pnpm/store/v11"; mkdir -p "$P/files"; mb "$P/files/a" 2
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV pnpm_store)"
verifica T-PNPM "scan mostra o store do pnpm com ID e 'ate'" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|D[0-9]*|pnpm_store|2|ate'" _ "$S"
OUT="$(roda limpar-dev --sessao "$SID" --itens "$ID")"
verifica T-PNPMb "pnpm store prune chamado e espaço liberado" sh -c "grep -q 'pnpm store prune' '$CALLS' && [ ! -e '$P/files' ] && printf '%s' \"\$1\" | grep -q '^LIBERADO|$ID|2'" _ "$OUT"
for comando in "add react" "-r install" "--filter web add react" "dev"; do
  novo_ambiente; duble_pnpm
  P="$H/Library/pnpm/store/v11"; mkdir -p "$P/files"; mb "$P/files/a" 1
  S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV pnpm_store)"
  # shellcheck disable=SC2086
  processo_falso pnpm $comando
  OUT="$(roda limpar-dev --sessao "$SID" --itens "$ID")"; sem_falso
  verifica "T-PNPM-RODANDO($comando)" "pnpm rodando: recusa pnpm_rodando" sh -c "printf '%s' \"\$1\" | grep -q 'pnpm_rodando' && [ -e '$P/files/a' ]" _ "$OUT"
done
for comando in "dlx create-x" "exec tsc"; do
  novo_ambiente; duble_pnpm
  P="$H/Library/pnpm/store/v11"; mkdir -p "$P/files"; mb "$P/files/a" 1
  S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV pnpm_store)"
  # shellcheck disable=SC2086
  processo_falso pnpm $comando
  OUT="$(roda limpar-dev --sessao "$SID" --itens "$ID")"; sem_falso
  verifica "T-PNPM-DLX($comando)" "pnpm dlx/exec não bloqueia" sh -c "printf '%s' \"\$1\" | grep -q '^LIBERADO|$ID'" _ "$OUT"
done
novo_ambiente; duble_pnpm
P="$H/Library/pnpm/store/v11"; mkdir -p "$P/files"; mb "$P/files/a" 1
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV pnpm_store)"
mkdir -p "$H/outro-store/files"
OUT="$(DUBLE_PNPM_STORE="$H/outro-store" roda limpar-dev --sessao "$SID" --itens "$ID")"
verifica T-PNPMc "store mudou entre scan e ação: recusa" sh -c "printf '%s' \"\$1\" | grep -q 'caminho_mudou' && ! grep -q 'store prune' '$CALLS'" _ "$OUT"

# ---------- T-CAMINHO ----------
novo_ambiente; duble_npm
FORA="$T/fora-do-home"; mkdir -p "$FORA/_cacache"; mb "$FORA/_cacache/f" 1
ln -s "$FORA" "$H/link-npm"
S="$(DUBLE_NPM_CACHE="$H/link-npm" roda scan)"
verifica T-CAMINHO "link para fora do HOME: sem ID" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|-|npm_cache|1|fora_da_pasta_pessoal'" _ "$S"
S="$(DUBLE_NPM_CACHE="$H/../fora-do-home" roda scan)"
verifica T-CAMINHOb "'..' para fora do HOME: sem ID" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|-|npm_cache|1|fora_da_pasta_pessoal'" _ "$S"
mkdir -p "${H}x-npm/_cacache"
S="$(DUBLE_NPM_CACHE="${H}x-npm" roda scan)"
verifica T-CAMINHOc "pasta irmã de nome parecido: sem ID" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|-|npm_cache|.*|fora_da_pasta_pessoal'" _ "$S"
verifica T-CAMINHOd "nada fora do HOME foi apagado" test -e "$FORA/_cacache/f"
novo_ambiente; duble_npm
mkdir -p "$H/.npm/_cacache" "$H/npm2/_cacache"; mb "$H/.npm/_cacache/f" 1; mb "$H/npm2/_cacache/f" 1
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
OUT="$(DUBLE_NPM_CACHE="$H/npm2" roda limpar-dev --sessao "$SID" --itens "$ID")"
verifica T-CAMINHOe "cache mudou entre scan e ação: recusa" sh -c "printf '%s' \"\$1\" | grep -q 'caminho_mudou' && [ -e '$H/.npm/_cacache/f' ] && [ -e '$H/npm2/_cacache/f' ]" _ "$OUT"

# ---------- T-KB / medição ----------
novo_ambiente; duble_npm
mkdir -p "$H/.npm/_cacache"; dd if=/dev/zero of="$H/.npm/_cacache/f" bs=1024 count=300 2>/dev/null
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
OUT="$(roda limpar-dev --sessao "$SID" --itens "$ID")"
verifica T-KB "300 KB apagados = 'menos de 1 MB', não falha" sh -c "printf '%s' \"\$1\" | grep -q '^LIBERADO|$ID|<1'" _ "$OUT"
novo_ambiente; duble_pnpm
P="$H/Library/pnpm/store/v11"; mkdir -p "$P/files"; mb "$P/files/a" 1
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV pnpm_store)"
OUT="$(DUBLE_PNPM_MODO=zero roda limpar-dev --sessao "$SID" --itens "$ID")"
verifica T-KBb "pnpm sem nada a tirar = NADA_A_LIMPAR" sh -c "printf '%s' \"\$1\" | grep -q '^NADA_A_LIMPAR|$ID'" _ "$OUT"
novo_ambiente; duble_npm
mkdir -p "$H/.npm/_cacache/d"; mb "$H/.npm/_cacache/d/f" 1
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
OUT="$(DUBLE_NPM_MODO=sem_permissao roda limpar-dev --sessao "$SID" --itens "$ID")"
chmod 755 "$H/.npm/_cacache" 2>/dev/null
verifica T-KBc "não deu para medir depois = nao_mediu, nunca 0 liberado" sh -c "printf '%s' \"\$1\" | grep -q '^FALHOU|$ID|nao_mediu'" _ "$OUT"
novo_ambiente; duble_npm
mkdir -p "$H/.npm/_cacache"; mb "$H/.npm/_cacache/f1" 1; mb "$H/.npm/_cacache/f2" 1
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
OUT="$(DUBLE_NPM_MODO=metade roda limpar-dev --sessao "$SID" --itens "$ID")"
verifica T-KBd "apagou parte e saiu com erro = PARCIAL" sh -c "printf '%s' \"\$1\" | grep -q '^PARCIAL|$ID'" _ "$OUT"
OUT="$(roda limpar-dev --sessao "$SID" --itens "$ID")"
verifica T-KBe "PARCIAL não marca feito: dá para tentar de novo" sh -c "printf '%s' \"\$1\" | grep -q '^LIBERADO|$ID'" _ "$OUT"

# ---------- T-LIMPAR-DUPLO / T-CONCLUIR2 ----------
novo_ambiente; duble_npm
mkdir -p "$H/.npm/_cacache"; mb "$H/.npm/_cacache/f" 4
S="$(roda scan)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
DUBLE_NPM_DEVAGAR=1 roda limpar-dev --sessao "$SID" --itens "$ID" > "$T/o1" & P1=$!
DUBLE_NPM_DEVAGAR=1 roda limpar-dev --sessao "$SID" --itens "$ID" > "$T/o2" & P2=$!
wait "$P1" "$P2"
verifica T-LIMPAR-DUPLO "duas ao mesmo tempo: uma limpa, a outra recusa" sh -c \
  "[ \"\$(cat '$T/o1' '$T/o2' | grep -c '^LIBERADO')\" = 1 ] && cat '$T/o1' '$T/o2' | grep -Eq 'ja_feito|ocupado'"
OUT="$(roda concluir --sessao "$SID")"
verifica T-CONCLUIR2 "concluir soma o liberado uma vez só (4 MB)" sh -c "printf '%s' \"\$1\" | grep -q 'apagado_mb=4|'" _ "$OUT"

# ---------- T-PREV2 ----------
novo_ambiente; duble_npm; duble_pnpm
mkdir -p "$H/.npm/_cacache" "$H/Library/pnpm/store/v11/files"; mb "$H/.npm/_cacache/f" 1; mb "$H/Library/pnpm/store/v11/files/a" 1
A="$(soma_arvore "$H")"
S="$(roda previa)"; SID="$(sessao_de "$S")"; ID="$(id_de "$S" DEV npm_cache)"
roda limpar-dev --sessao "$SID" --itens "$ID" >/dev/null; C=$?
verifica T-PREV2 "prévia: limpar-dev recusado (código 7) e nada mudou" sh -c "[ '$C' = 7 ] && [ -e '$H/.npm/_cacache/f' ] && ! grep -q 'cache clean' '$CALLS'"
verifica T-PREV2b "prévia: arquivos do HOME falso iguais antes/depois (fora sessão e log)" test "$A" = "$(soma_arvore "$H")"

# ---------- T-DOCKER / T-DOCKER-OFF ----------
novo_ambiente; duble_docker
S="$(DUBLE_DOCKER_ORFAS="" roda scan)"
verifica T-DOCKER "sem imagens órfãs: nada_a_limpar, sem ID" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|-|docker|0|nada_a_limpar'" _ "$S"
S="$(DUBLE_DOCKER_ORFAS="sha256:bbb" roda scan)"
verifica T-DOCKERb "órfã de 200MB: 'até' ~190 MB, sem ID" sh -c "printf '%s' \"\$1\" | grep -Eq '^DEV\\|-\\|docker\\|19[0-9]\\|colima'" _ "$S"
verifica T-DOCKERc "nunca chama prune, rm, volume ou container" sh -c "! grep -Eq '^docker(.* )? ?(prune|rm|rmi|volume|container)( |\$)' '$CALLS'"
S="$(DUBLE_DOCKER=off roda scan)"
verifica T-DOCKER-OFF "serviço parado: 'parado' e o scan termina" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|-|docker|parado' && printf '%s' \"\$1\" | grep -q '^FIM_SCAN'" _ "$S"

# ---------- T-LIMITE (comando que nunca termina) ----------
novo_ambiente; duble_docker; duble_ollama
INI="$(date +%s)"
S="$(OPT_LIMITE_S=1 DUBLE_DOCKER=trava DUBLE_OLLAMA=trava roda scan)"
FIM="$(date +%s)"
verifica T-LIMITE "docker e ollama travados: scan termina e marca sem_resposta" sh -c \
  "printf '%s' \"\$1\" | grep -q '^DEV|-|docker|sem_resposta' && printf '%s' \"\$1\" | grep -q '^IA|-|ollama|sem_resposta' && printf '%s' \"\$1\" | grep -q '^FIM_SCAN' && [ $((FIM-INI)) -le 6 ]" _ "$S"
sleep 0.3
verifica T-LIMITEb "nenhum processo do dublê sobra vivo" sh -c "! ps -axo args= | grep -Eq '^sleep 100[12]\$|$T/bin/(docker|ollama) '"

# ---------- T-COREPACK ----------
novo_ambiente; duble_pnpm
INI="$(date +%s)"
S="$(OPT_LIMITE_S=1 DUBLE_PNPM_MODO=pede_entrada roda scan)"
verifica T-COREPACK "pnpm que pede entrada não trava: nao_disponivel" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|-|pnpm|nao_disponivel'" _ "$S"
S="$(OPT_LIMITE_S=1 DUBLE_PNPM_MODO=trava roda scan)"; FIM="$(date +%s)"
verifica T-COREPACKb "pnpm que fica baixando: sem_resposta e o scan termina" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|-|pnpm|sem_resposta' && [ $((FIM-INI)) -le 8 ]" _ "$S"

# ---------- T-COLIMA ----------
novo_ambiente
mkdir -p "$H/.colima/_lima/_disks/colima"; dd if=/dev/zero of="$H/.colima/_lima/_disks/colima/datadisk" bs=1 count=0 seek=2147483648 2>/dev/null
S="$(roda scan)"
verifica T-COLIMA "disco esparso: mostra o du (~0), não os 2 GB do ls" sh -c "printf '%s' \"\$1\" | grep -q '^DEV|-|colima|0|volta_ao_reiniciar' && ! grep -q '^colima' '$CALLS'" _ "$S"

# ---------- T-IA ----------
novo_ambiente; duble_ollama
mkdir -p "$H/.cache/huggingface/hub" "$H/.cache/whisper" "$H/.lmstudio/models"
mb "$H/.cache/huggingface/hub/m" 2; mb "$H/.cache/whisper/w" 1; mb "$H/.lmstudio/models/l" 1
S="$(roda scan)"
verifica T-IA "modelos aparecem sem ID" sh -c "printf '%s' \"\$1\" | grep -q '^IA|-|ollama|modelo-a:8b|' && printf '%s' \"\$1\" | grep -q '^IA|-|huggingface|2' && printf '%s' \"\$1\" | grep -q '^IA|-|whisper|1' && printf '%s' \"\$1\" | grep -q '^IA|-|lmstudio|1'" _ "$S"
verifica T-IAb "ollama rm nunca é chamado" sh -c "! grep -q '^ollama rm' '$CALLS'"
SID="$(sessao_de "$S")"
OUT="$(roda limpar-dev --sessao "$SID" --itens D99)"
verifica T-IAc "ID inventado recusado" sh -c "printf '%s' \"\$1\" | grep -q 'item_inexistente_na_sessao'" _ "$OUT"

# ---------- T-IPHONE ----------
novo_ambiente
B="$H/Library/Application Support/MobileSync/Backup"; mkdir -p "$B/aparelho1" "$B/aparelho2"; mb "$B/aparelho1/f" 2
S="$(roda scan)"
verifica T-IPHONE "backups contados, nada tocado" sh -c "printf '%s' \"\$1\" | grep -q '^BACKUP_IPHONE|2|2' && [ -e '$B/aparelho1/f' ]" _ "$S"
chmod 000 "$B"
S="$(roda scan)"; chmod 755 "$B"
verifica T-IPHONEb "sem permissão: aviso e o scan termina" sh -c "printf '%s' \"\$1\" | grep -q '^AVISO|backup_iphone_sem_permissao' && printf '%s' \"\$1\" | grep -q '^FIM_SCAN'" _ "$S"

# ---------- T-APPSUP-EXC / T-APPSUP-AGIR ----------
novo_ambiente
mkdir -p "$H/Library/Application Support/MobileSync/Backup/x" "$H/Library/Application Support/multimodal-models"
mb "$H/Library/Application Support/MobileSync/Backup/x/f" 2; mb "$H/Library/Application Support/multimodal-models/m" 2
S="$(roda scan)"; SID="$(sessao_de "$S")"
verifica T-APPSUP-EXC "MobileSync e modelos fora da categoria [5]" sh -c "! printf '%s' \"\$1\" | grep -Eq '^APPSUPPORT\\|.*(MobileSync|multimodal-models)' && printf '%s' \"\$1\" | grep -q '^IA|-|appsupport|multimodal-models|2'" _ "$S"
OUT="$(roda quarentena --sessao "$SID" --itens S1)"
verifica T-APPSUP-EXCb "ID forjado recusado e nada movido" sh -c "! printf '%s' \"\$1\" | grep -q '^MOVIDO' && [ -e '$H/Library/Application Support/MobileSync/Backup/x/f' ]" _ "$OUT"
novo_ambiente
ANTIGO="$T/optimizer-2.0.0.sh"
if git -C "$REPO" show 407fda7:optimizer/scripts/optimizer.sh > "$ANTIGO" 2>/dev/null; then
  mkdir -p "$H/Library/Application Support/MobileSync/Backup/x"; mb "$H/Library/Application Support/MobileSync/Backup/x/f" 2
  S="$(/bin/bash "$ANTIGO" scan)"; SID="$(sessao_de "$S")"; IDV="$(id_de "$S" APPSUPPORT MobileSync)"
  OUT="$(roda quarentena --sessao "$SID" --itens "$IDV")"
  verifica T-APPSUP-AGIR "sessão da 2.0.0 com ID de MobileSync: recusa protegido" sh -c "[ -n '$IDV' ] && printf '%s' \"\$1\" | grep -q '^RECUSADO|$IDV|protegido' && [ -e '$H/Library/Application Support/MobileSync/Backup/x/f' ]" _ "$OUT"
else
  pula T-APPSUP-AGIR "sem o histórico do git, não há o script 2.0.0 para criar a sessão antiga"
fi
novo_ambiente
export HF_HOME="$H/Library/Caches/hf"; mkdir -p "$HF_HOME/hub"; mb "$HF_HOME/hub/m" 1
S="$(roda scan)"; unset HF_HOME
verifica T-APPSUP-AGIRb "HF_HOME dentro de Caches: não vira cache limpável" sh -c "! printf '%s' \"\$1\" | grep -q '^CACHE|C[0-9]*|hf|'" _ "$S"

# ---------- T-NODEMOD* ----------
novo_ambiente
nm() { mkdir -p "$H/$1/node_modules/pkg"; mb "$H/$1/node_modules/pkg/f" "${2:-1}"; echo '{}' > "$H/$1/package.json"; }
nm "p/a/b/c/d/e/f"            # node_modules no nível 8
nm "q/a/b/c/d/e/f/g"          # nível 9: não acha
nm "Documents/proj-doc"; nm "Desktop/proj-mesa"
nm "Library/proj-lib"; nm ".escondida/proj"; nm "Pictures/proj"; nm "App.app/proj"; nm "Fotos.photoslibrary/proj"
mkdir -p "$H/proj-pai/node_modules/dep/node_modules/x"; mb "$H/proj-pai/node_modules/dep/node_modules/x/f" 1; echo '{}' > "$H/proj-pai/package.json"
ln -s "$H/p" "$H/link-p"
S="$(roda scan)"
verifica T-NODEMOD "acha no nível 8, não no 9" sh -c "printf '%s' \"\$1\" | grep -q '^NODEMOD|-|.*p/a/b/c/d/e/f|' && ! printf '%s' \"\$1\" | grep -q 'q/a/b/c/d/e/f/g'" _ "$S"
verifica T-NODEMOD-PULA "pula Biblioteca, escondida, Fotos, pacotes de app, link e node_modules dentro de node_modules" sh -c \
  "! printf '%s' \"\$1\" | grep -Eq '^NODEMOD.*(Library/proj-lib|\\.escondida|Pictures/proj|App\\.app|photoslibrary|link-p|node_modules/dep)' && printf '%s' \"\$1\" | grep -q '^NODEMOD|-|.*proj-pai|'" _ "$S"
verifica T-NODEMOD-PULAb "acha em Documentos e na Mesa" sh -c "printf '%s' \"\$1\" | grep -q 'Documents/proj-doc' && printf '%s' \"\$1\" | grep -q 'Desktop/proj-mesa'" _ "$S"
chmod 000 "$H/Documents"
S="$(OPT_LOGDIR="$T/logs" roda scan)"; chmod 755 "$H/Documents"
verifica T-NODEMOD-PERM "Documentos sem permissão: aviso e o scan termina" sh -c "printf '%s' \"\$1\" | grep -q '^AVISO|sem_permissao|.*Documents' && printf '%s' \"\$1\" | grep -q '^FIM_SCAN'" _ "$S"
novo_ambiente
i=1; while [ "$i" -le 12 ]; do mkdir -p "$H/proj$i/node_modules"; mb "$H/proj$i/node_modules/f" "$i"; i=$((i+1)); done
S="$(roda scan)"
verifica T-NODEMOD-PERMb "só os 10 maiores" sh -c "[ \"\$(printf '%s\n' \"\$1\" | grep -c '^NODEMOD|-|')\" = 10 ] && ! printf '%s' \"\$1\" | grep -q 'proj1|'" _ "$S"
novo_ambiente
mkdir -p "$H/velho/node_modules" "$H/sem-manifesto/node_modules"; mb "$H/velho/node_modules/f" 1; mb "$H/sem-manifesto/node_modules/f" 1
echo '{}' > "$H/velho/package.json"; echo x > "$H/velho/pnpm-lock.yaml"; echo x > "$H/velho/bun.lock"
touch -t 202601010000 "$H/velho/package.json"; touch -t 202601010000 "$H/velho/pnpm-lock.yaml"
touch -t "$(date -v-10d +%Y%m%d%H%M)" "$H/velho/bun.lock"
S="$(roda scan)"
verifica T-NODEMOD-DIAS "dias pelo arquivo mais recente (bun.lock: 10 dias); sem manifesto: '-'" sh -c \
  "printf '%s' \"\$1\" | grep -Eq '^NODEMOD\\|-\\|.*velho\\|1\\|1[01]$' && printf '%s' \"\$1\" | grep -q '^NODEMOD|-|.*sem-manifesto|1|-$'" _ "$S"

# ---------- T-SISTEMA ----------
novo_ambiente
FIX="$T/apfs.txt"
cat > "$FIX" <<'EOF'
CONTAINER disk3
    |   APFS Volume Disk (Role):   disk3s1 (System)
    |   Capacity Consumed:         13761384448 B (13.8 GB)
    |   APFS Volume Disk (Role):   disk3s2 (Preboot)
    |   Capacity Consumed:         9689440256 B (9.7 GB)
    |   APFS Volume Disk (Role):   disk3s3 (Recovery)
    |   Capacity Consumed:         1519566848 B (1.5 GB)
    |   APFS Volume Disk (Role):   disk3s6 (VM)
    |   Capacity Consumed:         15032414208 B (15.0 GB)
    |   APFS Volume Disk (Role):   disk3s7 (No specific role)
    |   Capacity Consumed:         1048576 B (1.0 MB)
FIM disk3
CONTAINER disk5
    |   APFS Volume Disk (Role):   disk5s1 (VM)
    |   Capacity Consumed:         99999999999 B (100.0 GB)
FIM disk5
EOF
S="$(DUBLE_DISKUTIL="$FIX" roda scan)"
verifica T-SISTEMA "lê só o container de / (VM 14336 MB, não o do disco externo)" sh -c \
  "printf '%s' \"\$1\" | grep -q '^SISTEMA|vm|14336' && printf '%s' \"\$1\" | grep -q '^SISTEMA|preboot|9241' && printf '%s' \"\$1\" | grep -q '^SISTEMA|recovery|1449' && ! printf '%s' \"\$1\" | grep -q '95367'" _ "$S"
S="$(roda scan)"
verifica T-SISTEMAb "diskutil falha: sem linhas de volume e o scan termina" sh -c "! printf '%s' \"\$1\" | grep -q '^SISTEMA|vm' && printf '%s' \"\$1\" | grep -q '^SISTEMA|snapshots|' && printf '%s' \"\$1\" | grep -q '^FIM_SCAN'" _ "$S"

# ---------- T-SEM-FERRAMENTA ----------
novo_ambiente
S="$(roda scan)"
verifica T-SEM-FERRAMENTA "sem npm/pnpm/docker/ollama: nao_instalado e o scan termina" sh -c \
  "printf '%s' \"\$1\" | grep -q '^DEV|-|npm|nao_instalado' && printf '%s' \"\$1\" | grep -q '^DEV|-|pnpm|nao_instalado' && printf '%s' \"\$1\" | grep -q '^DEV|-|docker|nao_instalado' && printf '%s' \"\$1\" | grep -q '^FIM_SCAN'" _ "$S"

# ---------- T-CR ----------
novo_ambiente
CR="$(printf '\r')"
mkdir -p "$H/Library/Caches/App${CR}x"; mb "$H/Library/Caches/App${CR}x/f" 1
echo d > "$H/Downloads/a${CR}b.dmg"
mkdir -p "$H/Library/Application Support/Sup${CR}x"; mb "$H/Library/Application Support/Sup${CR}x/f" 2
S="$(roda scan)"; SID="$(sessao_de "$S")"
verifica T-CR "\\r no nome vira NOME_INVALIDO nas 3 categorias" sh -c "[ \"\$(printf '%s\n' \"\$1\" | grep -c '^NOME_INVALIDO')\" = 3 ]" _ "$S"
verifica T-CRb "\\r não entra na sessão" sh -c "! grep -q \"\$(printf '\\r')\" '$TRASH/.sessoes/$SID.tsv'"

# ---------- T-SKILL3 ----------
verifica T-SKILL3 "skill: menus novos, regra 1 ampliada, nunca oferecer apagar o que só aparece, 2.1.0" sh -c \
  "grep -q 'Versão esperada: 2.1.0' '$SKILL' && grep -q 'limpar-dev' '$SKILL' && grep -q '\\[8\\]' '$SKILL' && grep -q '\\[9\\]' '$SKILL' && grep -q '\\[10\\]' '$SKILL' && for t in npm pnpm docker colima ollama hf xcrun; do sed -n '/^1\\. \\*\\*Nunca execute/,/^2\\./p' '$SKILL' | grep -q \"\\\`\$t\\\`\" || exit 1; done && grep -qi 'nunca ofereça apagar' '$SKILL' && grep -q 'pnpm_rodando' '$SKILL' && grep -q 'instalacao_em_andamento' '$SKILL'"

# ---------- T-REAL / T-SC / T-BASH ----------
verifica T-REAL "nenhum binário por caminho absoluto e nenhum ls" sh -c \
  "! sed '1d' '$SCRIPT' | grep -vE '^[[:space:]]*#' | grep -qE '/(usr/)?s?bin/[a-z]' && ! grep -vE '^[[:space:]]*#' '$SCRIPT' | grep -qE '(^|[;&|(]|\\\$\\()[[:space:]]*ls[[:space:]]'"
if [ -n "$SHELLCHECK" ]; then
  verifica T-SC "shellcheck sem aviso" "$SHELLCHECK" -s bash "$SCRIPT" "$REPO/install.sh" "$REPO/tests/run.sh"
else
  falha T-SC "shellcheck não encontrado"
fi
verifica T-BASH "rodando em bash 3.2" sh -c "/bin/bash -c 'echo \$BASH_VERSION' | grep -q '^3\\.2'"

echo ""
echo "Resultado: $PASSOU passaram, $FALHOU falharam, $PULOU pulados."
[ "$PULOU" -eq 0 ] || echo "Pulados (não rodaram):$LISTA_PULOS"
[ "$FALHOU" -eq 0 ] || { echo "Falharam:$LISTA_FALHAS"; exit 1; }
