#!/bin/bash
# ============================================================
#  Mac Optimizer — script de apoio da skill /optimizer
#  Compatível com o bash 3.2 do macOS. Chamado pela skill com:
#    bash "${CLAUDE_SKILL_DIR}/scripts/optimizer.sh" <subcomando> [opções]
#
#  Saída: uma linha por fato, campos separados por "|".
#  Regras de segurança (ver README):
#    - nada é apagado ou movido no modo prévia;
#    - toda ação exige o ID da sessão do scan e os IDs dos itens aprovados;
#    - a quarentena nunca sobrescreve; restaurar nunca sobrescreve;
#    - o script nunca chama sudo.
# ============================================================
set -u

VERSAO="2.1.0"

# ---------- Raízes (sobrescrevíveis por variável, para teste) ----------
# Usa ${VAR-padrão}: variável definida como vazia continua vazia e a trava recusa.
OPT_CACHES="${OPT_CACHES-$HOME/Library/Caches}"
OPT_DOWNLOADS="${OPT_DOWNLOADS-$HOME/Downloads}"
OPT_APPSUPPORT="${OPT_APPSUPPORT-$HOME/Library/Application Support}"
OPT_USER_AGENTS="${OPT_USER_AGENTS-$HOME/Library/LaunchAgents}"
OPT_SYS_AGENT_DIRS="${OPT_SYS_AGENT_DIRS-/Library/LaunchAgents:/Library/LaunchDaemons}"
OPT_APPS_DIRS="${OPT_APPS_DIRS-/Applications:$HOME/Applications}"
OPT_TRASH="${OPT_TRASH-$HOME/.mac-optimizer-trash}"
OPT_LOGDIR="${OPT_LOGDIR-$HOME/Documents/Mac Optimizer/logs}"
OPT_DISK="${OPT_DISK-/System/Volumes/Data}"
OPT_SESSAO_MAX_MIN="${OPT_SESSAO_MAX_MIN-60}"
OPT_MIN_MB_APPSUPPORT="${OPT_MIN_MB_APPSUPPORT-10}"
# Limite de tempo de cada comando externo: consultas (padrão 10 s) e as duas limpezas npm/pnpm (padrão 10 min).
OPT_LIMITE_S="${OPT_LIMITE_S:-10}"
OPT_LIMITE_LIMPEZA_S="${OPT_LIMITE_LIMPEZA_S:-600}"
# Pastas de modelos de IA dentro de Application Support, separadas por ":". Só aparecem (linha IA): nunca têm ID,
# nunca entram na categoria [5] e nunca vão para a quarentena. Para ampliar, acrescente o nome aqui.
PASTAS_IA_APPSUPPORT="multimodal-models:LM Studio:ollama:Ollama:huggingface:GPT4All:jan:Jan"
# npm e pnpm nunca perguntam nada nem baixam o próprio gerenciador (Corepack; doc do Corepack, README).
export COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0

TAB="$(printf '\t')"
CR="$(printf '\r')"
PRAZO_DIAS=30
# Nome para mostrar numa linha de saída: "|" vira "¦" e tab/retorno de carro/quebra de linha viram espaço,
# para o nome nunca quebrar os campos. O caminho verdadeiro fica só na sessão / manifest.
campo() { local s="${1//|/¦}"; s="${s//$TAB/ }"; s="${s//$CR/ }"; printf '%s' "${s//$'\n'/ }"; }
# Caminho com quebra de linha não entra na sessão nem na quarentena: o script nunca age sobre ele
# (o nome "limpo" poderia coincidir com outro arquivo). A pessoa renomeia pelo Finder.
tem_quebra() { case "$1" in *$'\n'*) return 0;; esac; return 1; }
# No scan, TAB também barra: a sessão é separada por tab, e um nome com tab faria o ID apontar
# para outro item (achado da revisão do Codex). Itens antigos com TAB na quarentena seguem listáveis.
# Retorno de carro (\r) também barra (2.1.0, revisão do Codex no plano).
nome_ruim() { case "$1" in *$'\n'*|*"$TAB"*|*"$CR"*) return 0;; esac; return 1; }
nome_invalido() { # categoria caminho kb
  echo "NOME_INVALIDO|$1|$(campo "$(basename "$2")")|$(mb_de_kb "$3")|$(campo "$(dirname "$2")")"
}
APPS_IDX=""
TRAVADO=0
NPM_LOGS=""
NDEV=0
SNAP_N=0
LOGF=""
SF=""
MODO=""
SESSAO=""

# ---------- Utilidades ----------
die() { echo "ERRO|$1"; exit "${2:-1}"; }
agora() { date +%s; }
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }
minusc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
kb_de() { local k; k="$(du -sk "$1" 2>/dev/null | awk 'NR==1{print $1}')"; echo "${k:-0}"; }  # NR==1: nome com quebra de linha
mb_de_kb() { awk -v k="$1" 'BEGIN{printf "%.0f", k/1024}'; }
mtime_de() { stat -f %m "$1" 2>/dev/null || echo 0; }
inode_de() { stat -f %i "$1" 2>/dev/null || echo 0; }
plist_val() { [ -f "$1" ] || return 0; plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }
limpar_tmp() {
  [ -n "$APPS_IDX" ] && [ -f "$APPS_IDX" ] && command rm -f "$APPS_IDX"
  [ "$TRAVADO" = 1 ] && destravar
  [ -n "$NPM_LOGS" ] && [ -d "$NPM_LOGS" ] && command rm -rf "$NPM_LOGS"
  return 0
}
trap limpar_tmp EXIT

# Roda um comando externo com limite de tempo, no bash 3.2 e sem o comando `timeout` (regra do projeto).
# Sempre a partir da pasta pessoal (não lê .npmrc de outra pasta) e sem entrada (nada fica esperando resposta).
# Saída do comando no stdout. Código: o do comando; 124 = estourou o limite. Ao estourar, interrompe direto o
# processo e os filhos dele (pkill -P); nunca pelo grupo, que derrubaria o próprio script (revisão r3).
com_limite() {
  local lim="$1" out pid i=0 max rc
  shift
  out="$(mktemp -t optimizer-lim)" || return 125
  ( cd "$HOME" 2>/dev/null || exit 125; exec "$@" ) </dev/null >"$out" 2>/dev/null &
  pid=$!
  max=$(( lim * 10 ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$max" ]; then
      disown "$pid" 2>/dev/null
      pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
      cat "$out"; command rm -f "$out"
      return 124
    fi
    sleep 0.1; i=$((i+1))
  done
  wait "$pid"; rc=$?
  cat "$out"; command rm -f "$out"
  return "$rc"
}

# Caminho real (links resolvidos) de uma pasta que existe; vazio se não der para entrar nela.
real_de() { ( cd -P "$1" 2>/dev/null && pwd -P ); }
HOME_REAL="$(real_de "$HOME")"
# Pasta real estritamente dentro da pasta pessoal real: não aceita a própria pasta pessoal, ".." nem pasta irmã
# de nome parecido (ex.: uma pasta "anax" ao lado da pasta pessoal "ana").
dentro_do_home() { [ -n "$1" ] && [ -n "$HOME_REAL" ] || return 1; case "$1" in "$HOME_REAL"/?*) return 0;; esac; return 1; }
# Caminho para mostrar: dentro da pasta pessoal vira "~/...".
# shellcheck disable=SC2088  # o "~" aqui é texto para mostrar, não para expandir
rel() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}";; *) printf '%s' "$1";; esac; }
# MB para mostrar: entre 1 KB e 1 MB vira "<1" (revisão do Codex: nunca "0" quando algo saiu).
mb_texto() { if [ "$1" -gt 0 ] && [ "$1" -lt 1024 ]; then printf '<1'; else mb_de_kb "$1"; fi; }

eh_pasta_ia() { case ":$PASTAS_IA_APPSUPPORT:" in *":$1:"*) return 0;; esac; return 1; }
# Pastas que o script nunca apaga nem move — backups de iPhone, modelos de IA e o disco do Colima —, mesmo com ID
# de uma sessão criada pela 2.0.0 e mesmo achadas por outra categoria (ex.: HF_HOME dentro de Caches).
pastas_protegidas() {
  local n old_ifs
  printf '%s\n' "$OPT_APPSUPPORT/MobileSync" "$HOME/.ollama" "$HOME/.cache/huggingface" "$HOME/.lmstudio" "$HOME/.colima"
  [ -n "${HF_HOME:-}" ] && printf '%s\n' "$HF_HOME"
  old_ifs="$IFS"; IFS=':'
  for n in $PASTAS_IA_APPSUPPORT; do printf '%s\n' "$OPT_APPSUPPORT/$n"; done
  IFS="$old_ifs"
  return 0
}
protegido() {
  local d alvo p rp x
  d="$(real_de "$(dirname "$1")")"; [ -n "$d" ] || d="$(dirname "$1")"
  alvo="${d%/}/$(basename "$1")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p="${p%/}"; rp="$(real_de "$p")"; [ -n "$rp" ] || rp="$p"
    for x in "$alvo" "${1%/}"; do
      case "$x/" in "$rp"/*|"$p"/*) return 0;; esac
      case "$rp/" in "$x"/*) return 0;; esac
      case "$p/" in "$x"/*) return 0;; esac
    done
  done < <(pastas_protegidas)
  return 1
}

log_l() { [ -n "$LOGF" ] || return 0; printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1" >> "$LOGF"; }

# Trava de raiz: recusa raiz vazia, "/", a pasta do usuário, pasta acima dela ou inexistente.
raiz_valida() {
  local nome="$1" v="$2"
  [ -n "$v" ] || die "raiz_vazia:$nome" 9
  v="${v%/}"
  [ -n "$v" ] || die "raiz_invalida:$nome" 9
  [ "$v" != "${HOME%/}" ] || die "raiz_invalida:$nome" 9
  case "${HOME%/}/" in "$v"/*) die "raiz_invalida:$nome" 9;; esac
  return 0
}
raiz_ok() {
  raiz_valida "$1" "$2"
  [ -d "$2" ] || die "raiz_inexistente:$1" 9
}

# Caminho precisa estar diretamente dentro da raiz (sem "..").
dentro_de() {
  local raiz="${2%/}" p="$1"
  case "$p" in *"/../"*|*"/..") return 1;; esac
  [ "$(dirname "$p")" = "$raiz" ]
}

# ---------- Índice de apps instalados ----------
indexar_apps() {
  APPS_IDX="$(mktemp -t optimizer-apps)" || die "mktemp_falhou" 1
  local d app nome bn bid old_ifs
  old_ifs="$IFS"; IFS=':'
  # shellcheck disable=SC2086
  set -- $OPT_APPS_DIRS
  IFS="$old_ifs"
  for d in "$@"; do
    [ -d "$d" ] || continue
    while IFS= read -r -d '' app; do
      nome="$(basename "$app" .app)"
      bn="$(plist_val "$app/Contents/Info.plist" CFBundleName)"
      bid="$(plist_val "$app/Contents/Info.plist" CFBundleIdentifier)"
      printf '%s\t%s\t%s\n' "$(norm "$nome")" "$(norm "$bn")" "$(minusc "$bid")" >> "$APPS_IDX"
    done < <(find "$d" -maxdepth 2 -name '*.app' -type d -print0 2>/dev/null)
  done
  touch "$APPS_IDX"
}

# Nome normalizado casa com nome do app ou CFBundleName (prefixo nos dois sentidos, mínimo 3 letras).
casa_app() {
  local n="$1" a b id c
  [ "${#n}" -ge 3 ] || return 1
  while IFS="$TAB" read -r a b id; do
    for c in "$a" "$b"; do
      [ "${#c}" -ge 3 ] || continue
      case "$c" in "$n"*) return 0;; esac
      case "$n" in "$c"*) return 0;; esac
    done
  done < "$APPS_IDX"
  return 1
}

casa_bundle_id() {
  local f="$1" a b id
  while IFS="$TAB" read -r a b id; do
    [ -n "$id" ] && [ "$f" = "$id" ] && return 0
  done < "$APPS_IDX"
  return 1
}

# Primeiros dois pedaços do rótulo (ex.: com.google) iguais aos de um app instalado.
casa_fabricante() {
  local v a b id
  v="$(printf '%s' "$1" | awk -F. 'NF>=3{print $1"."$2}')"
  [ -n "$v" ] || return 1
  while IFS="$TAB" read -r a b id; do
    case "$id" in "$v".*) return 0;; esac
  done < "$APPS_IDX"
  return 1
}

# ---------- Sessão ----------
sess_dir() { echo "$OPT_TRASH/.sessoes"; }

limpar_sessoes_vencidas() {
  local f criado limite
  limite=$(( $(agora) - OPT_SESSAO_MAX_MIN * 60 ))
  for f in "$(sess_dir)"/*.tsv; do
    [ -f "$f" ] || continue
    criado="$(awk -F'\t' '$1=="#criado"{print $2}' "$f")"
    [ "${criado:-0}" -lt "$limite" ] && command rm -f "$f"
  done
  return 0
}

carregar_sessao() {
  SESSAO="$1"
  [ -n "$SESSAO" ] || die "sessao_ausente" 5
  case "$SESSAO" in *[!A-Za-z0-9-]*) die "sessao_invalida" 5;; esac
  SF="$(sess_dir)/$SESSAO.tsv"
  [ -f "$SF" ] || die "sessao_inexistente: rode o scan de novo" 5
  local criado idade
  criado="$(awk -F'\t' '$1=="#criado"{print $2}' "$SF")"
  idade=$(( ( $(agora) - ${criado:-0} ) / 60 ))
  [ "$idade" -le "$OPT_SESSAO_MAX_MIN" ] || die "sessao_vencida: rode o scan de novo" 6
  MODO="$(awk -F'\t' '$1=="#modo"{print $2}' "$SF")"
  LOGF="$OPT_LOGDIR/$SESSAO.log"
}

exigir_real() { [ "$MODO" = "real" ] || die "modo_previa: nada é apagado nem movido" 7; }

# Linha do item na sessão: ID cat caminho kb mtime inode classe
item_da_sessao() { awk -F'\t' -v id="$1" '$1==id' "$SF" | head -1; }

registrar_feito() { printf '#feito\t%s\t%s\n' "$1" "$2" >> "$SF"; }

disco_livre_kb() { df -k "$OPT_DISK" 2>/dev/null | tail -1 | awk '{print $4}'; }

# ---------- Manifest da quarentena ----------
# qid  epoch  categoria  caminho_original  caminho_quarentena  kb
manifest() { echo "$OPT_TRASH/manifest.tsv"; }

# Trava da quarentena: só um processo por vez escolhe número e grava o registro (achado do Codex).
# Trava de processo que já morreu é liberada.
trava_dir() { echo "$OPT_TRASH/.trava"; }
travar() {
  local d i=0 max="${OPT_TRAVA_TENTATIVAS:-100}" dono
  d="$(trava_dir)"
  while ! mkdir "$d" 2>/dev/null; do
    dono="$(cat "$d/pid" 2>/dev/null)"
    if [ -n "$dono" ] && ! kill -0 "$dono" 2>/dev/null; then command rm -rf "$d"; continue; fi
    i=$((i+1)); [ "$i" -ge "$max" ] && return 1
    sleep 0.1
  done
  echo "$$" > "$d/pid"
}
destravar() { command rm -rf "$(trava_dir)"; }

proximo_qid() {
  local m; m="$(manifest)"
  [ -f "$m" ] || { echo 1; return; }
  awk -F'\t' 'BEGIN{x=0} $1+0>x{x=$1+0} END{print x+1}' "$m"
}

remover_do_manifest() {
  local m tmp; m="$(manifest)"; tmp="$m.tmp.$$"
  travar || return 1
  awk -F'\t' -v q="$1" '$1!=q' "$m" > "$tmp" && mv "$tmp" "$m"
  destravar
}

# Move para <trash>/<data>/<categoria>/<n>-<nome>. Nunca sobrescreve.
mover_para_quarentena() {
  local src="$1" cat="$2" kb="$3" dia dir qid dest
  dia="$(date +%Y-%m-%d)"
  dir="$OPT_TRASH/$dia/$cat"
  mkdir -p "$dir" || { echo "FALHOU|criar_pasta"; return 1; }
  travar || { echo "FALHOU|ocupado"; return 1; }
  qid="$(proximo_qid)"
  dest="$dir/$qid-$(basename "$src")"
  if [ -e "$dest" ]; then destravar; echo "FALHOU|destino_existe"; return 1; fi
  mv -n "$src" "$dest" 2>/dev/null
  if [ -e "$src" ] || [ ! -e "$dest" ]; then destravar; echo "FALHOU|nao_moveu"; return 1; fi
  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$qid" "$(agora)" "$cat" "$src" "$dest" "$kb" >> "$(manifest)" 2>/dev/null; then
    # sem registro, o item perderia o caminho de volta: desfaz a mudança (achado do Codex)
    mv -n "$dest" "$src" 2>/dev/null
    destravar
    if [ -e "$src" ]; then echo "FALHOU|registro_nao_gravou|item_devolvido"; else echo "FALHOU|registro_nao_gravou|item_em=$(campo "$dest")"; fi
    return 1
  fi
  destravar
  log_l "QUARENTENA categoria=$cat tamanho_kb=$kb"
  QID_MOVIDO="$qid"
  return 0
}

# ---------- SCAN ----------
cmd_scan() {
  local modo="$1"
  raiz_valida OPT_TRASH "$OPT_TRASH"
  raiz_valida OPT_LOGDIR "$OPT_LOGDIR"
  mkdir -p "$OPT_TRASH" "$(sess_dir)" "$OPT_LOGDIR" || die "nao_criou_pastas" 1
  limpar_sessoes_vencidas

  SESSAO="$(date +%Y%m%d-%H%M%S)-$$"
  SF="$(sess_dir)/$SESSAO.tsv"
  LOGF="$OPT_LOGDIR/$SESSAO.log"
  local livre; livre="$(disco_livre_kb)"
  {
    printf '#modo\t%s\n' "$modo"
    printf '#criado\t%s\n' "$(agora)"
    printf '#disco_livre_kb\t%s\n' "${livre:-0}"
  } > "$SF"
  echo "=== MAC OPTIMIZER — Sessão $SESSAO (modo $modo) ===" >> "$LOGF"
  log_l "SCAN iniciado modo=$modo"
  echo "SESSAO|$SESSAO|$modo"

  df -k "$OPT_DISK" 2>/dev/null | tail -1 | awk '{printf "DISCO|total_gb=%.0f|usado_gb=%.0f|livre_gb=%.0f\n", $2/1048576, $3/1048576, $4/1048576}'

  indexar_apps
  scan_caches
  scan_brew_pip
  scan_instaladores
  scan_appsupport
  scan_agentes
  scan_snapshots
  scan_dev
  scan_nodemod
  scan_ia
  scan_iphone
  scan_sistema
  scan_quarentena_resumo
  log_l "SCAN concluído"
  echo "FIM_SCAN|$SESSAO"
}

scan_caches() {
  local item nome kb n=0 total=0 aviso
  if [ ! -d "$OPT_CACHES" ]; then echo "CACHE_TOTAL|0"; return; fi
  for item in "$OPT_CACHES"/*; do
    [ -e "$item" ] || continue
    nome="$(basename "$item")"
    kb="$(kb_de "$item")"
    if nome_ruim "$item"; then nome_invalido cache "$item" "$kb"; continue; fi
    case "$nome" in
      ms-playwright) echo "CACHE_MANTIDO|$(campo "$nome")|$(mb_de_kb "$kb")|navegadores de teste: apagar obriga a baixar tudo de novo"; continue;;
      Homebrew|pip) echo "CACHE_MANTIDO|$(campo "$nome")|$(mb_de_kb "$kb")|limpo pela categoria Homebrew + pip"; continue;;
    esac
    if protegido "$item"; then echo "CACHE_MANTIDO|$(campo "$nome")|$(mb_de_kb "$kb")|modelos de IA: só mostro"; continue; fi
    if [ ! -w "$item" ]; then echo "CACHE_MANTIDO|$(campo "$nome")|$(mb_de_kb "$kb")|protegido pelo macOS"; continue; fi
    aviso=""
    if [ "${#nome}" -ge 4 ] && pgrep -if -- "$nome" >/dev/null 2>&1; then aviso="app_aberto"; fi
    n=$((n+1))
    printf 'C%s\tcache\t%s\t%s\t%s\t%s\t-\n' "$n" "$item" "$kb" "$(mtime_de "$item")" "$(inode_de "$item")" >> "$SF"
    echo "CACHE|C$n|$(campo "$nome")|$(mb_de_kb "$kb")|volta_sozinho|$aviso"
    total=$((total+kb))
  done
  echo "CACHE_TOTAL|$(mb_de_kb "$total")"
}

scan_brew_pip() {
  local out dir kb
  if ! command -v brew >/dev/null 2>&1; then
    echo "BREW|nao_instalado"
  else
    out="$(brew cleanup --dry-run 2>/dev/null | grep -i 'would free' | sed -n 's/.*approximately \([^ ]*\) of disk space.*/\1/p' | head -1)"
    if [ -n "$out" ]; then echo "BREW|$out"; else echo "BREW|nada"; fi
  fi
  if ! command -v pip3 >/dev/null 2>&1; then
    echo "PIP|nao_instalado"
  else
    dir="$(pip3 cache dir 2>/dev/null | tail -1)"
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      kb="$(kb_de "$dir")"
      if [ "$kb" -gt 0 ]; then echo "PIP|$(mb_de_kb "$kb")MB"; else echo "PIP|nada"; fi
    else
      echo "PIP|nada"
    fi
  fi
}

scan_instaladores() {
  local f nome base primeiro kb n=0 err tipo
  if [ ! -e "$OPT_DOWNLOADS" ]; then echo "INSTALADORES|0"; return; fi
  if [ ! -r "$OPT_DOWNLOADS" ] || [ ! -x "$OPT_DOWNLOADS" ]; then
    echo "AVISO|downloads_sem_permissao|$OPT_DOWNLOADS"; return
  fi
  err="$(mktemp -t optimizer-err)"
  while IFS= read -r -d '' f; do
    if nome_ruim "$f"; then nome_invalido dmgs "$f" "$(kb_de "$f")"; continue; fi
    nome="$(basename "$f")"
    base="${nome%.*}"
    primeiro="$(printf '%s' "$base" | awk -F'[-_ .(]' '{print $1}')"
    kb="$(kb_de "$f")"
    if casa_app "$(norm "$primeiro")" || casa_app "$(norm "$base")"; then tipo="seguro"; else tipo="duvida"; fi
    n=$((n+1))
    printf 'I%s\tdmgs\t%s\t%s\t%s\t%s\t%s\n' "$n" "$f" "$kb" "$(mtime_de "$f")" "$(inode_de "$f")" "$tipo" >> "$SF"
    echo "INSTALADOR|I$n|$tipo|$(campo "$nome")|$(mb_de_kb "$kb")"
  done < <(find "$OPT_DOWNLOADS" -maxdepth 2 \( -name '*.dmg' -o -name '*.pkg' \) -type f -print0 2>"$err")
  if grep -qi 'not permitted\|permission denied' "$err" 2>/dev/null; then
    echo "AVISO|downloads_sem_permissao|$OPT_DOWNLOADS"
  fi
  command rm -f "$err"
  echo "INSTALADORES|$n"
}

# Pasta genérica (ex.: "Caches") cujo conteúdo é de um app instalado (ex.: "notion-updater").
subpasta_de_app() {
  local s p
  for s in "$1"/*; do
    [ -e "$s" ] || continue
    p="$(basename "$s" | awk -F'[-_ .]' '{print $1}')"
    casa_app "$(norm "$p")" && return 0
  done
  return 1
}

scan_appsupport() {
  local item nome low kb n=0 cli min
  min=$((OPT_MIN_MB_APPSUPPORT * 1024))
  [ -d "$OPT_APPSUPPORT" ] || { echo "APPSUPPORT_TOTAL|0"; return; }
  for item in "$OPT_APPSUPPORT"/*; do
    [ -d "$item" ] || continue
    if nome_ruim "$item"; then nome_invalido appsupport "$item" "$(kb_de "$item")"; continue; fi
    nome="$(basename "$item")"
    low="$(minusc "$nome")"
    case "$low" in com.apple.*) continue;; esac
    # backups de iPhone e modelos de IA: só aparecem nas linhas BACKUP_IPHONE e IA (exceção aprovada, 2.1.0)
    [ "$nome" = "MobileSync" ] && continue
    eh_pasta_ia "$nome" && continue
    kb="$(kb_de "$item")"
    [ "$kb" -ge "$min" ] || continue
    casa_app "$(norm "$nome")" && continue
    casa_bundle_id "$low" && continue
    cli="$(printf '%s' "$low" | tr -cd 'a-z0-9._-')"
    if [ -n "$cli" ] && command -v "$cli" >/dev/null 2>&1; then continue; fi
    subpasta_de_app "$item" && continue
    n=$((n+1))
    printf 'S%s\tappsupport\t%s\t%s\t%s\t%s\ttalvez_orfao\n' "$n" "$item" "$kb" "$(mtime_de "$item")" "$(inode_de "$item")" >> "$SF"
    echo "APPSUPPORT|S$n|$(campo "$nome")|$(mb_de_kb "$kb")|talvez_orfao"
  done
  echo "APPSUPPORT_TOTAL|$n"
}

# Ordem: serviço do Homebrew pelo rótulo > de app instalado (fabricante) > programa na pasta do usuário >
# programa do Homebrew > desconhecido. Todos os argumentos são lidos antes de decidir.
classificar_agente() {
  local p="$1" low="$2" i arg prog em_home=0 em_brew=0
  case "$low" in homebrew.mxcl.*|sh.brew.*) echo "homebrew"; return;; esac
  if casa_fabricante "$low"; then echo "app_instalado"; return; fi
  prog="$(plist_val "$p" Program)"
  case "$prog" in "$HOME"/*) em_home=1;; /opt/homebrew/*|/usr/local/Cellar/*) em_brew=1;; esac
  i=0
  while [ "$i" -lt 10 ]; do
    arg="$(plist_val "$p" "ProgramArguments.$i")"
    [ -n "$arg" ] || break
    case "$arg" in "$HOME"/*) em_home=1;; /opt/homebrew/*|/usr/local/Cellar/*) em_brew=1;; esac
    i=$((i+1))
  done
  if [ "$em_home" = 1 ]; then echo "usuario"; return; fi
  if [ "$em_brew" = 1 ]; then echo "homebrew"; return; fi
  echo "desconhecido"
}

scan_agentes() {
  local p label low classe n=0 d old_ifs
  if [ -d "$OPT_USER_AGENTS" ]; then
    for p in "$OPT_USER_AGENTS"/*.plist; do
      [ -f "$p" ] || continue
      if nome_ruim "$p"; then nome_invalido launchagents "$p" "$(kb_de "$p")"; continue; fi
      label="$(basename "$p" .plist)"; low="$(minusc "$label")"
      classe="$(classificar_agente "$p" "$low")"
      if [ "$classe" = "desconhecido" ]; then
        n=$((n+1))
        printf 'A%s\tlaunchagents\t%s\t%s\t%s\t%s\t%s\n' "$n" "$p" "$(kb_de "$p")" "$(mtime_de "$p")" "$(inode_de "$p")" "$classe" >> "$SF"
        echo "AGENTE|A$n|$classe|usuario|$(campo "$label")"
      else
        echo "AGENTE|-|$classe|usuario|$(campo "$label")"
      fi
    done
  fi
  old_ifs="$IFS"; IFS=':'
  # shellcheck disable=SC2086
  set -- $OPT_SYS_AGENT_DIRS
  IFS="$old_ifs"
  for d in "$@"; do
    [ -d "$d" ] || continue
    for p in "$d"/*.plist; do
      [ -f "$p" ] || continue
      label="$(basename "$p" .plist)"; low="$(minusc "$label")"
      classe="$(classificar_agente "$p" "$low")"
      echo "AGENTE|-|$classe|sistema|$(campo "$label")|$d"
    done
  done
}

scan_snapshots() {
  if ! command -v tmutil >/dev/null 2>&1; then echo "SNAPSHOTS|0"; return; fi
  SNAP_N="$(com_limite "$OPT_LIMITE_S" tmutil listlocalsnapshots / | grep -c 'com.apple.TimeMachine')"
  echo "SNAPSHOTS|${SNAP_N:-0}"
}

# ---------- Sobras de programação, modelos de IA, backups, Dados do Sistema (2.1.0) ----------
# Só npm e pnpm recebem ID. Linha da sessão: ID categoria caminho_real kb mtime inode -
dev_com_id() { # categoria caminho_real kb rotulo
  NDEV=$((NDEV+1))
  printf 'D%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$NDEV" "$1" "$2" "$3" "$(mtime_de "$2")" "$(inode_de "$2")" >> "$SF"
  echo "DEV|D$NDEV|$1|$(mb_texto "$3")|$4"
}

# Todo npm roda com --logs-dir numa pasta temporária (apagada no fim): o npm grava um log a cada execução e apaga
# os antigos da pasta de logs; assim a prévia não apaga nada da pessoa (revisão do Codex no código).
# Chamar no shell principal, antes de usar "$NPM_LOGS".
preparar_npm_logs() { [ -n "$NPM_LOGS" ] || NPM_LOGS="$(mktemp -d -t optimizer-npmlogs)" || NPM_LOGS=""; }

# Última linha da saída de uma consulta (npm config get cache / pnpm store path). Código como o de com_limite.
consulta() { local o rc; o="$(com_limite "$OPT_LIMITE_S" "$@")"; rc=$?; printf '%s' "$o" | tail -1; return "$rc"; }

scan_npm() {
  local bruto rc pai kb
  if ! command -v npm >/dev/null 2>&1; then
    if [ -d "$HOME/.npm/_cacache" ]; then echo "DEV|-|npm_cache|$(mb_texto "$(kb_de "$HOME/.npm/_cacache")")|npm_fora_do_path"
    else echo "DEV|-|npm|nao_instalado"; fi
    return
  fi
  preparar_npm_logs
  [ -n "$NPM_LOGS" ] || { echo "DEV|-|npm|nao_disponivel"; return; }
  bruto="$(consulta npm config get cache --logs-dir="$NPM_LOGS")"; rc=$?
  [ "$rc" = 124 ] && { echo "DEV|-|npm|sem_resposta"; return; }
  if [ "$rc" != 0 ] || [ -z "$bruto" ] || nome_ruim "$bruto"; then echo "DEV|-|npm|nao_disponivel"; return; fi
  pai="$(real_de "$bruto")"
  if [ -z "$pai" ] || [ ! -d "$pai/_cacache" ]; then echo "DEV|-|npm_cache|0|nada_a_limpar"; return; fi
  kb="$(kb_de "$pai/_cacache")"
  if ! dentro_do_home "$pai" || nome_ruim "$pai"; then echo "DEV|-|npm_cache|$(mb_texto "$kb")|fora_da_pasta_pessoal"; return; fi
  if protegido "$pai"; then echo "DEV|-|npm_cache|$(mb_texto "$kb")|protegido"; return; fi
  dev_com_id npm_cache "$pai" "$kb" volta_sozinho
}

scan_pnpm() {
  local bruto rc st kb
  command -v pnpm >/dev/null 2>&1 || { echo "DEV|-|pnpm|nao_instalado"; return; }
  bruto="$(consulta pnpm store path)"; rc=$?
  [ "$rc" = 124 ] && { echo "DEV|-|pnpm|sem_resposta"; return; }
  if [ "$rc" != 0 ] || [ -z "$bruto" ] || nome_ruim "$bruto"; then echo "DEV|-|pnpm|nao_disponivel"; return; fi
  st="$(real_de "$bruto")"
  [ -n "$st" ] || { echo "DEV|-|pnpm_store|0|nada_a_limpar"; return; }
  kb="$(kb_de "$st")"
  if ! dentro_do_home "$st" || nome_ruim "$st"; then echo "DEV|-|pnpm_store|$(mb_texto "$kb")|fora_da_pasta_pessoal"; return; fi
  if protegido "$st"; then echo "DEV|-|pnpm_store|$(mb_texto "$kb")|protegido"; return; fi
  dev_com_id pnpm_store "$st" "$kb" ate
}

# Docker (só mostra): "até X MB" = soma do UniqueSize das imagens órfãs ("UNIQUE SIZE is the amount of space
# that's only used by a given image", doc do docker system df) que nenhum container usa (as usadas não saem). O cache de build não é medido nesta versão.
scan_docker() {
  local rc ctx orfas tam mb
  command -v docker >/dev/null 2>&1 || { echo "DEV|-|docker|nao_instalado"; return; }
  com_limite "$OPT_LIMITE_S" docker info >/dev/null; rc=$?
  [ "$rc" = 124 ] && { echo "DEV|-|docker|sem_resposta"; return; }
  [ "$rc" = 0 ] || { echo "DEV|-|docker|parado"; return; }
  ctx="$(consulta docker context show)"
  orfas="$(com_limite "$OPT_LIMITE_S" docker images -f dangling=true -q --no-trunc)"; rc=$?
  [ "$rc" = 0 ] || { echo "DEV|-|docker|sem_resposta"; return; }
  [ -n "$orfas" ] || { echo "DEV|-|docker|0|nada_a_limpar"; return; }
  tam="$(com_limite "$OPT_LIMITE_S" docker system df -v --format '{{range .Images}}{{.ID}} {{.UniqueSize}} {{.Containers}}{{println}}{{end}}')"; rc=$?
  [ "$rc" = 0 ] || { echo "DEV|-|docker|sem_resposta"; return; }
  mb="$(awk 'NR==FNR{if($1!="")o[$1]=1; next}
    ($1 in o) && $3=="0" {v=$2; n=v; sub(/[A-Za-z]+$/,"",n); u=v; sub(/^[0-9.]+/,"",u); m=1
      if(u=="kB"||u=="KB")m=1e3; else if(u=="MB")m=1e6; else if(u=="GB")m=1e9; else if(u=="TB")m=1e12
      s+=n*m}
    END{printf "%.0f", s/1048576}' <(printf '%s\n' "$orfas") <(printf '%s\n' "$tam"))"
  if [ "${mb:-0}" = 0 ]; then echo "DEV|-|docker|0|nada_a_limpar"; else echo "DEV|-|docker|$mb|$(campo "${ctx:-docker}")"; fi
}

scan_dev() {
  local d
  scan_npm
  scan_pnpm
  d="$HOME/Library/Developer/Xcode/DerivedData"
  [ -d "$d" ] && echo "DEV|-|xcode_deriveddata|$(mb_de_kb "$(kb_de "$d")")|volta_sozinho_mas_nao_limpo_nesta_versao"
  d="$HOME/Library/Developer/Xcode/Archives"
  [ -d "$d" ] && echo "DEV|-|xcode_archives|$(mb_de_kb "$(kb_de "$d")")|nao_volta"
  scan_docker
  # Colima: tamanho real por du (o arquivo do disco é esparso; o tamanho máximo não interessa)
  d="$HOME/.colima/_lima/_disks"
  [ -d "$d" ] && echo "DEV|-|colima|$(mb_de_kb "$(kb_de "$d")")|volta_ao_reiniciar"
  return 0
}

# Dias desde a alteração mais recente de manifesto/lockfile do projeto; "-" se não houver nenhum ou a data
# estiver no futuro. Não é "a última vez que o projeto foi usado".
dias_manifesto() {
  local f m maior=0 agora_s
  for f in package.json package-lock.json pnpm-lock.yaml yarn.lock bun.lockb bun.lock; do
    [ -f "$1/$f" ] || continue
    m="$(mtime_de "$1/$f")"; [ "$m" -gt "$maior" ] && maior="$m"
  done
  agora_s="$(agora)"
  if [ "$maior" -le 0 ] || [ "$maior" -gt "$agora_s" ]; then echo "-"; return; fi
  echo $(( (agora_s - maior) / 86400 ))
}

# node_modules (só mostra os 10 maiores): a partir da pasta pessoal, até 8 níveis, sem seguir link, sem entrar
# num node_modules já achado; pula Library, pastas escondidas, Fotos/Música/Filmes/Público e pacotes de app.
scan_nodemod() {
  local err lista f kb dias proj n p
  err="$(mktemp -t optimizer-err)"; lista="$(mktemp -t optimizer-nm)"
  while IFS= read -r -d '' f; do
    nome_ruim "$f" && continue
    proj="$(dirname "$f")"
    printf '%s\t%s\t%s\n' "$(kb_de "$f")" "$(dias_manifesto "$proj")" "$proj" >> "$lista"
  done < <(find "$HOME" -mindepth 1 -maxdepth 8 \( -path "$HOME/Library" -o -path "$HOME/Pictures" -o -path "$HOME/Music" \
             -o -path "$HOME/Movies" -o -path "$HOME/Public" -o -name '.*' -o -name '*.app' -o -name '*.photoslibrary' \
             -o -name '*.musiclibrary' \) -prune -o -type d -name node_modules -print0 -prune 2>"$err")
  n="$(awk 'END{print NR}' "$lista")"
  sort -t "$TAB" -k1,1nr "$lista" | head -10 | while IFS="$TAB" read -r kb dias proj; do
    echo "NODEMOD|-|$(campo "$(rel "$proj")")|$(mb_de_kb "$kb")|$dias"
  done
  grep -Ei 'permission denied|not permitted' "$err" 2>/dev/null | sed -E 's/^find: (.*): [^:]*$/\1/' | sort -u | head -5 |
    while IFS= read -r p; do echo "AVISO|sem_permissao|$(campo "$(rel "$p")")"; done
  command rm -f "$err" "$lista"
  echo "NODEMOD_TOTAL|$n"
}

scan_ia() {
  local saida rc d n old_ifs
  if command -v ollama >/dev/null 2>&1; then
    saida="$(com_limite "$OPT_LIMITE_S" ollama list)"; rc=$?
  else
    rc=127
  fi
  if [ "$rc" = 124 ]; then
    echo "IA|-|ollama|sem_resposta"
  elif [ "$rc" = 0 ]; then
    printf '%s\n' "$saida" | awk 'NR>1 && NF>=4 {
      u=$4; m=1; if(u=="KB"||u=="kB")m=1e3; else if(u=="MB")m=1e6; else if(u=="GB")m=1e9; else if(u=="TB")m=1e12
      mod=""; for(i=5;i<=NF;i++) mod=mod (i>5?" ":"") $i
      gsub(/\|/,"¦",$1); gsub(/\|/,"¦",mod)
      printf "IA|-|ollama|%s|%.0f|%s\n", $1, $3*m/1048576, mod }'
  elif [ -d "$HOME/.ollama/models" ]; then
    echo "IA|-|ollama|total|$(mb_de_kb "$(kb_de "$HOME/.ollama/models")")|-"
  fi
  d="${HF_HOME:-$HOME/.cache/huggingface}"
  [ -d "$d" ] && echo "IA|-|huggingface|$(mb_de_kb "$(kb_de "$d")")"
  [ -d "$HOME/.cache/whisper" ] && echo "IA|-|whisper|$(mb_de_kb "$(kb_de "$HOME/.cache/whisper")")"
  [ -d "$HOME/.lmstudio/models" ] && echo "IA|-|lmstudio|$(mb_de_kb "$(kb_de "$HOME/.lmstudio/models")")"
  old_ifs="$IFS"; IFS=':'
  for n in $PASTAS_IA_APPSUPPORT; do
    IFS="$old_ifs"
    [ -d "$OPT_APPSUPPORT/$n" ] && echo "IA|-|appsupport|$(campo "$n")|$(mb_de_kb "$(kb_de "$OPT_APPSUPPORT/$n")")"
    IFS=':'
  done
  IFS="$old_ifs"
  return 0
}

# Backups de iPhone/iPad (só mostra; apagar só pelo Finder > aparelho > Gerenciar Backups).
scan_iphone() {
  local ms="$OPT_APPSUPPORT/MobileSync" b="$OPT_APPSUPPORT/MobileSync/Backup" n err
  # pasta de cima sem permissão: "Backup" parece não existir, mas pode existir (revisão do Codex no código)
  if [ -e "$ms" ] && { [ ! -r "$ms" ] || [ ! -x "$ms" ]; }; then echo "AVISO|backup_iphone_sem_permissao"; return; fi
  [ -e "$b" ] || { echo "BACKUP_IPHONE|0|0"; return; }
  if [ ! -r "$b" ] || [ ! -x "$b" ]; then echo "AVISO|backup_iphone_sem_permissao"; return; fi
  err="$(mktemp -t optimizer-err)"
  n="$(find "$b" -mindepth 1 -maxdepth 1 -type d 2>"$err" | awk 'END{print NR}')"
  if grep -qi 'not permitted\|permission denied' "$err" 2>/dev/null; then
    command rm -f "$err"; echo "AVISO|backup_iphone_sem_permissao"; return
  fi
  command rm -f "$err"
  echo "BACKUP_IPHONE|$n|$(mb_de_kb "$(kb_de "$b")")"
}

# Dados do Sistema, parte por parte (só mostra). Volumes lidos só do container APFS do disco de "/".
scan_sistema() {
  local cont total=0 p
  if command -v diskutil >/dev/null 2>&1 && command -v plutil >/dev/null 2>&1; then
    cont="$(com_limite "$OPT_LIMITE_S" diskutil info -plist / | plutil -extract APFSContainerReference raw - 2>/dev/null)"
    case "$cont" in ""|*[!a-z0-9]*) cont="";; esac
    if [ -n "$cont" ]; then
      com_limite "$OPT_LIMITE_S" diskutil apfs list "$cont" | awk '
        /APFS Volume Disk \(Role\):/ { r=$0; sub(/.*\(/, "", r); sub(/\).*/, "", r); next }
        /Capacity Consumed:/ { b=$0; sub(/.*Consumed:[[:space:]]*/, "", b); sub(/[[:space:]].*/, "", b)
          n=""; if (r=="VM") n="vm"; else if (r=="Preboot") n="preboot"; else if (r=="Recovery") n="recovery"
          if (n!="" && b ~ /^[0-9]+$/ && !(n in visto)) { visto[n]=1; printf "SISTEMA|%s|%.0f\n", n, b/1048576 }
          r="" }'
    fi
  fi
  echo "SISTEMA|snapshots|${SNAP_N:-0}"
  echo "SISTEMA|caches|$(mb_de_kb "$(kb_de "$OPT_CACHES")")"
  echo "SISTEMA|logs|$(mb_de_kb "$(kb_de "$HOME/Library/Logs")")"
  for p in "$HOME/.npm" "$HOME/.ollama" "$HOME/.colima" "$HOME/.cache" "$HOME/Library/pnpm" "$HOME/Library/Developer"; do
    [ -e "$p" ] && total=$((total + $(kb_de "$p")))
  done
  echo "SISTEMA|pastas_escondidas|$(mb_de_kb "$total")"
}

scan_quarentena_resumo() {
  local n=0 kb=0 l
  while IFS= read -r l; do
    n=$((n+1)); kb=$((kb + $(printf '%s' "$l" | cut -f5) ))
  done < <(listar_quarentena_kb)
  echo "QUARENTENA|$n|$(mb_de_kb "$kb")"
}

# ---------- AÇÕES ----------
cmd_limpar_caches() {
  raiz_ok OPT_CACHES "$OPT_CACHES"; raiz_ok OPT_TRASH "$OPT_TRASH"
  carregar_sessao "$1"; exigir_real
  local ids="$2" id linha cat path kb inode antes depois liberado total=0
  [ -n "$ids" ] || die "itens_ausentes" 8
  for id in $(printf '%s' "$ids" | tr ',' ' '); do
    linha="$(item_da_sessao "$id")"
    [ -n "$linha" ] || { echo "RECUSADO|$id|item_inexistente_na_sessao"; continue; }
    cat="$(printf '%s' "$linha" | cut -f2)"; path="$(printf '%s' "$linha" | cut -f3)"; inode="$(printf '%s' "$linha" | cut -f6)"
    [ "$cat" = "cache" ] || { echo "RECUSADO|$id|nao_e_cache"; continue; }
    dentro_de "$path" "$OPT_CACHES" || { echo "RECUSADO|$id|fora_da_pasta_de_caches"; continue; }
    protegido "$path" && { echo "RECUSADO|$id|protegido"; continue; }
    [ -e "$path" ] || { echo "RECUSADO|$id|nao_existe_mais"; continue; }
    [ "$(inode_de "$path")" = "$inode" ] || { echo "RECUSADO|$id|item_mudou"; continue; }
    antes="$(kb_de "$path")"
    command rm -rf "$path" 2>/dev/null
    if [ -e "$path" ]; then depois="$(kb_de "$path")"; else depois=0; fi
    liberado=$((antes - depois)); [ "$liberado" -lt 0 ] && liberado=0
    total=$((total + liberado))
    if [ -e "$path" ]; then echo "PARCIAL|$id|$(mb_de_kb "$liberado")|protegido_pelo_macOS"; else echo "APAGADO|$id|$(mb_de_kb "$liberado")"; fi
  done
  registrar_feito apagado "$total"
  log_l "APAGADO caches total_kb=$total"
  echo "CACHES_LIBERADO|$(mb_de_kb "$total")"
}

cmd_limpar_brew_pip() {
  raiz_ok OPT_TRASH "$OPT_TRASH"
  carregar_sessao "$1"; exigir_real
  local out kb_b=0 dir antes depois
  if command -v brew >/dev/null 2>&1; then
    out="$(brew cleanup --prune=all 2>/dev/null | sed -n 's/.*freed approximately \([^ ]*\) of disk space.*/\1/p' | tail -1)"
    echo "BREW_LIBERADO|${out:-0}"
    log_l "CLEANED brew ${out:-0}"
  else
    echo "BREW_LIBERADO|nao_instalado"
  fi
  if command -v pip3 >/dev/null 2>&1; then
    dir="$(pip3 cache dir 2>/dev/null | tail -1)"
    antes=0; [ -n "$dir" ] && [ -d "$dir" ] && antes="$(kb_de "$dir")"
    pip3 cache purge >/dev/null 2>&1
    depois=0; [ -n "$dir" ] && [ -d "$dir" ] && depois="$(kb_de "$dir")"
    kb_b=$((antes - depois)); [ "$kb_b" -lt 0 ] && kb_b=0
    registrar_feito apagado "$kb_b"
    echo "PIP_LIBERADO|$(mb_de_kb "$kb_b")"
    log_l "CLEANED pip total_kb=$kb_b"
  else
    echo "PIP_LIBERADO|nao_instalado"
  fi
  [ -n "${out:-}" ] && registrar_feito brew "$out"
  return 0
}

# Serviço carregado? Confere algumas vezes, porque o desligamento pode levar um instante.
carregado() {
  local i=0
  while [ "$i" -lt 5 ]; do
    launchctl print "gui/$1/$2" >/dev/null 2>&1 || return 1
    i=$((i+1)); [ "$i" -lt 5 ] && sleep 0.2
  done
  return 0
}

cmd_quarentena() {
  raiz_ok OPT_TRASH "$OPT_TRASH"
  carregar_sessao "$1"; exigir_real
  local ids="$2" id linha cat path kb mt raiz
  [ -n "$ids" ] || die "itens_ausentes" 8
  for id in $(printf '%s' "$ids" | tr ',' ' '); do
    linha="$(item_da_sessao "$id")"
    [ -n "$linha" ] || { echo "RECUSADO|$id|item_inexistente_na_sessao"; continue; }
    cat="$(printf '%s' "$linha" | cut -f2)"; path="$(printf '%s' "$linha" | cut -f3)"
    kb="$(printf '%s' "$linha" | cut -f4)"; mt="$(printf '%s' "$linha" | cut -f5)"
    case "$cat" in
      dmgs) raiz="$OPT_DOWNLOADS"; raiz_ok OPT_DOWNLOADS "$raiz"
            case "$path" in "${raiz%/}"/*) ;; *) echo "RECUSADO|$id|fora_de_downloads"; continue;; esac;;
      appsupport) raiz="$OPT_APPSUPPORT"; raiz_ok OPT_APPSUPPORT "$raiz"
            dentro_de "$path" "$raiz" || { echo "RECUSADO|$id|fora_de_application_support"; continue; };;
      *) echo "RECUSADO|$id|categoria_nao_permitida"; continue;;
    esac
    # backups de iPhone e modelos de IA: recusa também ID de sessão criada pela 2.0.0 (revisão do Codex)
    protegido "$path" && { echo "RECUSADO|$id|protegido"; continue; }
    [ -e "$path" ] || { echo "RECUSADO|$id|nao_existe_mais"; continue; }
    if [ "$(kb_de "$path")" != "$kb" ] || [ "$(mtime_de "$path")" != "$mt" ]; then
      echo "RECUSADO|$id|item_mudou_desde_o_scan"; continue
    fi
    QID_MOVIDO=""
    if mover_para_quarentena "$path" "$cat" "$kb"; then
      registrar_feito quarentena "$kb"
      echo "MOVIDO|$id|Q$QID_MOVIDO|$(mb_de_kb "$kb")"
    else
      echo "RECUSADO|$id|nao_moveu"
    fi
  done
}

# ---------- limpar-dev: cache do npm e store do pnpm (2.1.0) ----------
# Instalação em andamento: lê a lista de processos uma vez (o próprio grep não entra nela).
# npm: bloqueiam os comandos que instalam — install, ci, update, install-test e install-ci-test —, escritos de
# qualquer forma que o npm aceita (o npm põe no processo o comando como foi digitado). npm exec e npx, usados
# pelos servidores MCP, não bloqueiam. Lista gerada do próprio npm (ver plano, §9, para refazer):
NPM_INSTALA='add|ci|cit|clean-install|clean-install-|clean-install-t|clean-install-te|clean-install-tes|clean-install-test|i|ic|in|ins|inst|insta|instal|install|install-ci|install-ci-|install-ci-t|install-ci-te|install-ci-tes|install-ci-test|install-cl|install-cle|install-clea|install-clean|install-t|install-te|install-tes|install-test|isnt|isnta|isntal|isntall|isntall-|isntall-c|isntall-cl|isntall-cle|isntall-clea|isntall-clean|it|si|sit|ud|udp|udpa|udpat|udpate|up|upd|upda|updat|update|upg|upgr|upgra|upgrad|upgrade'
instalando_npm() {
  local p; p="$(ps -axo args= 2>/dev/null)"
  printf '%s\n' "$p" | grep -Eq "(^|/)npm(-cli\\.js)?[[:space:]]+($NPM_INSTALA)([[:space:]]|\$)"
}
# pnpm: qualquer pnpm rodando bloqueia, menos pnpm exec. pnpm dlx também bloqueia: o store prune apaga o cache
# do dlx vencido (doc do pnpm), mesmo de um servidor dlx que ainda está rodando (revisão do Codex no código).
pnpm_rodando() {
  local p; p="$(ps -axo args= 2>/dev/null)"
  printf '%s\n' "$p" | grep -E '(^|/)pnpm(\.cjs|\.mjs)?([[:space:]]|$)' |
    grep -Evq '(^|/)pnpm(\.cjs|\.mjs)?[[:space:]]+exec([[:space:]]|$)'
}
ja_limpo() { awk -F'\t' -v id="$1" '$1=="#limpo" && $2==id{f=1} END{exit !f}' "$SF"; }

limpar_dev_item() {
  local id="$1" linha cat gravado bruto rc atual alvo antes depois liberado mb errf
  linha="$(item_da_sessao "$id")"
  [ -n "$linha" ] || { echo "RECUSADO|$id|item_inexistente_na_sessao"; return; }
  cat="$(printf '%s' "$linha" | cut -f2)"; gravado="$(printf '%s' "$linha" | cut -f3)"
  case "$cat" in npm_cache|pnpm_store) ;; *) echo "RECUSADO|$id|nao_e_sobra_de_programacao"; return;; esac
  ja_limpo "$id" && { echo "RECUSADO|$id|ja_feito"; return; }
  if [ "$cat" = npm_cache ]; then
    instalando_npm && { echo "RECUSADO|$id|instalacao_em_andamento"; return; }
    command -v npm >/dev/null 2>&1 || { echo "RECUSADO|$id|npm_nao_encontrado"; return; }
    preparar_npm_logs
    [ -n "$NPM_LOGS" ] || { echo "RECUSADO|$id|nao_disponivel"; return; }
    bruto="$(consulta npm config get cache --logs-dir="$NPM_LOGS")"; rc=$?
  else
    pnpm_rodando && { echo "RECUSADO|$id|pnpm_rodando"; return; }
    command -v pnpm >/dev/null 2>&1 || { echo "RECUSADO|$id|pnpm_nao_encontrado"; return; }
    bruto="$(consulta pnpm store path)"; rc=$?
  fi
  [ "$rc" = 124 ] && { echo "RECUSADO|$id|sem_resposta"; return; }
  [ "$rc" = 0 ] || { echo "RECUSADO|$id|nao_disponivel"; return; }
  # o caminho real tem de ser o mesmo do scan e estar dentro da pasta pessoal (revisão do Codex)
  atual="$(real_de "$bruto")"
  { [ -n "$atual" ] && [ "$atual" = "$gravado" ]; } || { echo "RECUSADO|$id|caminho_mudou"; return; }
  dentro_do_home "$atual" || { echo "RECUSADO|$id|fora_da_pasta_pessoal"; return; }
  protegido "$atual" && { echo "RECUSADO|$id|protegido"; return; }
  if [ "$cat" = npm_cache ]; then alvo="$atual/_cacache"; else alvo="$atual"; fi
  [ -d "$alvo" ] || { echo "RECUSADO|$id|nao_existe_mais"; return; }
  antes="$(kb_de "$alvo")"
  if [ "$cat" = npm_cache ]; then
    # o npm acrescenta "_cacache" sozinho: recebe a pasta-mãe (revisão r2)
    com_limite "$OPT_LIMITE_LIMPEZA_S" npm cache clean --force --cache "$atual" --logs-dir="$NPM_LOGS" >/dev/null; rc=$?
  else
    com_limite "$OPT_LIMITE_LIMPEZA_S" pnpm store prune >/dev/null; rc=$?
  fi
  # medição depois: pasta ausente = 0 (o npm apaga o _cacache inteiro); erro de leitura = não mediu, nunca 0
  if [ ! -e "$alvo" ]; then
    depois=0
  else
    errf="$(mktemp -t optimizer-err)"
    depois="$(du -sk "$alvo" 2>"$errf" | awk 'NR==1{print $1}')"
    if [ -s "$errf" ] || [ -z "$depois" ]; then
      command rm -f "$errf"
      echo "FALHOU|$id|nao_mediu"; log_l "LIMPAR_DEV categoria=$cat nao_mediu rc=$rc"; return
    fi
    command rm -f "$errf"
  fi
  liberado=$((antes - depois)); [ "$liberado" -lt 0 ] && liberado=0
  [ "$liberado" -gt 0 ] && registrar_feito apagado "$liberado"
  mb="$(mb_texto "$liberado")"
  log_l "LIMPAR_DEV categoria=$cat liberado_kb=$liberado rc=$rc"
  # decidido em KB, não em MB arredondado (revisão do Codex)
  if [ "$liberado" -eq 0 ]; then
    if [ "$rc" = 124 ]; then echo "FALHOU|$id|sem_resposta"
    elif [ "$rc" = 0 ] && { [ "$cat" = pnpm_store ] || [ ! -e "$alvo" ]; }; then
      printf '#limpo\t%s\n' "$id" >> "$SF"; echo "NADA_A_LIMPAR|$id"
    else echo "FALHOU|$id|nada_liberado"
    fi
  elif [ "$rc" != 0 ] || { [ "$cat" = npm_cache ] && [ -e "$alvo" ]; }; then
    if [ "$rc" = 124 ]; then echo "PARCIAL|$id|$mb|sem_resposta"; else echo "PARCIAL|$id|$mb"; fi
  else
    printf '#limpo\t%s\n' "$id" >> "$SF"
    echo "LIBERADO|$id|$mb"
  fi
}

cmd_limpar_dev() {
  raiz_ok OPT_TRASH "$OPT_TRASH"
  carregar_sessao "$1"; exigir_real
  local ids="$2" id
  [ -n "$ids" ] || die "itens_ausentes" 8
  # uma limpeza por vez, da validação ao registro (mesma trava da quarentena; revisão do Codex)
  if ! travar; then
    for id in $(printf '%s' "$ids" | tr ',' ' '); do echo "RECUSADO|$id|ocupado"; done
    return 0
  fi
  TRAVADO=1
  for id in $(printf '%s' "$ids" | tr ',' ' '); do limpar_dev_item "$id"; done
  destravar; TRAVADO=0
  return 0
}

cmd_remover_agente() {
  raiz_ok OPT_TRASH "$OPT_TRASH"; raiz_ok OPT_USER_AGENTS "$OPT_USER_AGENTS"
  carregar_sessao "$1"; exigir_real
  local ids="$2" id linha cat path kb mt uid label
  uid="$(id -u)"
  [ -n "$ids" ] || die "itens_ausentes" 8
  for id in $(printf '%s' "$ids" | tr ',' ' '); do
    linha="$(item_da_sessao "$id")"
    [ -n "$linha" ] || { echo "RECUSADO|$id|item_inexistente_na_sessao"; continue; }
    cat="$(printf '%s' "$linha" | cut -f2)"; path="$(printf '%s' "$linha" | cut -f3)"
    kb="$(printf '%s' "$linha" | cut -f4)"; mt="$(printf '%s' "$linha" | cut -f5)"
    [ "$cat" = "launchagents" ] || { echo "RECUSADO|$id|nao_e_servico"; continue; }
    dentro_de "$path" "$OPT_USER_AGENTS" || { echo "RECUSADO|$id|so_servicos_do_usuario"; continue; }
    [ -e "$path" ] || { echo "RECUSADO|$id|nao_existe_mais"; continue; }
    [ "$(mtime_de "$path")" = "$mt" ] || { echo "RECUSADO|$id|item_mudou_desde_o_scan"; continue; }
    label="$(plist_val "$path" Label)"; [ -n "$label" ] || label="$(basename "$path" .plist)"
    if carregado "$uid" "$label"; then
      launchctl bootout "gui/$uid" "$path" >/dev/null 2>&1
      # só move depois de confirmar que parou (achado do Codex)
      if carregado "$uid" "$label"; then echo "RECUSADO|$id|nao_desligou"; continue; fi
    fi
    QID_MOVIDO=""
    if mover_para_quarentena "$path" "launchagents" "$kb"; then
      registrar_feito quarentena "$kb"
      echo "SERVICO_DESLIGADO|$id|Q$QID_MOVIDO"
    else
      echo "RECUSADO|$id|nao_moveu"
    fi
  done
}

# ---------- QUARENTENA: listar / restaurar / apagar de vez ----------
# Linha interna (separada por tab): qid tipo categoria nome kb dias caminho
# ID: Q<n> para itens com manifest; QA<cksum do caminho> para itens do formato antigo (estável).
listar_quarentena_kb() {
  local m qid ep cat orig dest kb dias d c item agora_s dia_s
  m="$(manifest)"; agora_s="$(agora)"
  [ -d "$OPT_TRASH" ] || return 0
  if [ -f "$m" ]; then
    while IFS="$TAB" read -r qid ep cat orig dest kb; do
      [ -n "$qid" ] || continue
      [ -e "$dest" ] || continue
      dias=$(( (agora_s - ep) / 86400 ))
      printf 'Q%s\tnovo\t%s\t%s\t%s\t%s\t%s\n' "$qid" "$cat" "$(campo "$(basename "$orig")")" "$kb" "$dias" "$dest"
    done < "$m"
  fi
  for d in "$OPT_TRASH"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
    [ -d "$d" ] || continue
    dia_s="$(date -j -f %Y-%m-%d "$(basename "$d")" +%s 2>/dev/null || echo "$agora_s")"
    for c in "$d"/*; do
      [ -d "$c" ] || continue
      for item in "$c"/*; do
        [ -e "$item" ] || continue
        if ! tem_quebra "$item" && [ -f "$m" ] && awk -F'\t' -v p="$item" '$5==p{f=1} END{exit !f}' "$m"; then continue; fi
        dias=$(( (agora_s - dia_s) / 86400 ))
        if tem_quebra "$item"; then
          # último campo = pasta (sem o nome): o script nunca age sobre este item
          printf 'QA%s\tnome_invalido\t%s\t%s\t%s\t%s\t%s\n' "$(printf '%s' "$item" | cksum | awk '{print $1}')" \
            "$(campo "$(basename "$c")")" "$(campo "$(basename "$item")")" "$(kb_de "$item")" "$dias" "$c"
          continue
        fi
        printf 'QA%s\tantigo\t%s\t%s\t%s\t%s\t%s\n' "$(printf '%s' "$item" | cksum | awk '{print $1}')" \
          "$(campo "$(basename "$c")")" "$(campo "$(basename "$item")")" "$(kb_de "$item")" "$dias" "$item"
      done
    done
  done
}

cmd_listar_quarentena() {
  local qid tipo cat nome kb dias path n=0
  while IFS="$TAB" read -r qid tipo cat nome kb dias path; do
    n=$((n+1))
    echo "QITEM|$qid|$tipo|$cat|$(campo "$nome")|$(mb_de_kb "$kb")|$dias"
  done < <(listar_quarentena_kb)
  echo "QUARENTENA_ITENS|$n"
}

achar_qitem() {
  listar_quarentena_kb | awk -F'\t' -v q="$1" '$1==q' | head -1
}

cmd_restaurar() {
  local q="$1" destino="$2" linha tipo cat nome path orig alvo uid label
  [ -n "$q" ] || die "qid_ausente" 8
  raiz_ok OPT_TRASH "$OPT_TRASH"
  linha="$(achar_qitem "$q")"
  [ -n "$linha" ] || die "item_nao_encontrado_na_quarentena" 4
  [ "$(printf '%s' "$linha" | cut -f2)" = "nome_invalido" ] && {
    echo "RECUSADO|$q|nome_invalido|pasta=$(printf '%s' "$linha" | cut -f7-)|renomear_no_finder"; exit 11; }
  tipo="$(printf '%s' "$linha" | cut -f2)"; cat="$(printf '%s' "$linha" | cut -f3)"
  nome="$(printf '%s' "$linha" | cut -f4)"; path="$(printf '%s' "$linha" | cut -f7-)"
  case "$path" in "${OPT_TRASH%/}"/*) ;; *) die "fora_da_quarentena" 4;; esac
  if [ "$tipo" = "novo" ]; then
    orig="$(awk -F'\t' -v q="${q#Q}" '$1==q{print $4}' "$(manifest)" | head -1)"
    alvo="${destino:-$orig}"
  else
    if [ -z "$destino" ]; then echo "PRECISA_DESTINO|$q|sugestao=${OPT_DOWNLOADS%/}/$nome"; exit 3; fi
    alvo="$destino"
  fi
  if [ -e "$alvo" ]; then echo "RECUSADO|$q|destino_ocupado|sugestao=$alvo (restaurado)"; exit 4; fi
  mkdir -p "$(dirname "$alvo")" || die "nao_criou_pasta_destino" 1
  mv -n "$path" "$alvo" 2>/dev/null
  if [ -e "$path" ] || [ ! -e "$alvo" ]; then die "nao_restaurou" 1; fi
  [ "$tipo" = "novo" ] && remover_do_manifest "${q#Q}"
  echo "RESTAURADO|$q|$alvo"
  if [ "$cat" = "launchagents" ]; then
    uid="$(id -u)"; label="$(basename "$alvo" .plist)"
    launchctl bootstrap "gui/$uid" "$alvo" >/dev/null 2>&1
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then echo "SERVICO_RELIGADO|$label"; else echo "AVISO|servico_nao_religou|$label"; fi
  fi
}

cmd_apagar_de_vez() {
  local q="$1" antes="$2" linha tipo path kb dias
  [ -n "$q" ] || die "qid_ausente" 8
  raiz_ok OPT_TRASH "$OPT_TRASH"
  linha="$(achar_qitem "$q")"
  [ -n "$linha" ] || die "item_nao_encontrado_na_quarentena" 4
  [ "$(printf '%s' "$linha" | cut -f2)" = "nome_invalido" ] && {
    echo "RECUSADO|$q|nome_invalido|pasta=$(printf '%s' "$linha" | cut -f7-)|renomear_no_finder"; exit 11; }
  tipo="$(printf '%s' "$linha" | cut -f2)"; kb="$(printf '%s' "$linha" | cut -f5)"
  dias="$(printf '%s' "$linha" | cut -f6)"; path="$(printf '%s' "$linha" | cut -f7-)"
  if [ "${dias:-0}" -lt "$PRAZO_DIAS" ] && [ "$antes" != 1 ]; then
    echo "RECUSADO|$q|antes_do_prazo|dias=$dias|prazo=$PRAZO_DIAS"; exit 10
  fi
  case "$path" in "${OPT_TRASH%/}"/*/*/*) ;; *) die "fora_da_quarentena" 4;; esac
  case "$path" in *"/../"*|*"/..") die "caminho_invalido" 4;; esac
  command rm -rf "$path"
  [ -e "$path" ] && die "nao_apagou" 1
  [ "$tipo" = "novo" ] && remover_do_manifest "${q#Q}"
  echo "APAGADO_DE_VEZ|$q|$(mb_de_kb "$kb")"
}

# ---------- RELATÓRIO / CONCLUIR ----------
cmd_concluir() {
  carregar_sessao "$1"
  local apagado quarentena brew antes depois
  apagado="$(awk -F'\t' '$1=="#feito" && $2=="apagado"{s+=$3} END{print s+0}' "$SF")"
  quarentena="$(awk -F'\t' '$1=="#feito" && $2=="quarentena"{s+=$3} END{print s+0}' "$SF")"
  brew="$(awk -F'\t' '$1=="#feito" && $2=="brew"{print $3}' "$SF" | tail -1)"
  antes="$(awk -F'\t' '$1=="#disco_livre_kb"{print $2}' "$SF")"
  depois="$(disco_livre_kb)"
  echo "RELATORIO|apagado_mb=$(mb_de_kb "$apagado")|brew=${brew:-0}|quarentena_mb=$(mb_de_kb "$quarentena")"
  echo "RELATORIO_DISCO|livre_antes_gb=$(awk -v k="${antes:-0}" 'BEGIN{printf "%.1f", k/1048576}')|livre_agora_gb=$(awk -v k="${depois:-0}" 'BEGIN{printf "%.1f", k/1048576}')"
  echo "RELATORIO_NOTA|quarentena ainda ocupa espaço até ser apagada de vez (30 dias)"
  log_l "CONCLUÍDO apagado_kb=$apagado brew=${brew:-0} quarentena_kb=$quarentena"
  command rm -f "$SF"
  echo "LOG|$LOGF"
}

# ---------- Entrada ----------
uso() {
  cat <<'EOF'
Uso: optimizer.sh <subcomando> [opções]
  versao
  scan                      (modo real: depois pode agir)
  previa                    (só mostra; nada é apagado nem movido)
  limpar-caches   --sessao ID --itens C1,C2
  limpar-brew-pip --sessao ID
  limpar-dev      --sessao ID --itens D1,D2   (cache do npm / store do pnpm)
  quarentena      --sessao ID --itens I1,S2
  remover-agente  --sessao ID --itens A1
  concluir        --sessao ID
  listar-quarentena
  restaurar <QID> [--destino CAMINHO]
  apagar-de-vez <QID> [--antes-do-prazo]   (sem a opção, recusa item com menos de 30 dias)
EOF
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
ARG_SESSAO=""; ARG_ITENS=""; ARG_DESTINO=""; ARG_POS=""; ARG_ANTES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sessao) ARG_SESSAO="${2:-}"; shift 2 || shift;;
    --itens) ARG_ITENS="${2:-}"; shift 2 || shift;;
    --destino) ARG_DESTINO="${2:-}"; shift 2 || shift;;
    --antes-do-prazo) ARG_ANTES=1; shift;;
    *) ARG_POS="$1"; shift;;
  esac
done

case "$SUB" in
  versao) echo "VERSAO|$VERSAO";;
  scan) cmd_scan real;;
  previa) cmd_scan previa;;
  limpar-caches) cmd_limpar_caches "$ARG_SESSAO" "$ARG_ITENS";;
  limpar-brew-pip) cmd_limpar_brew_pip "$ARG_SESSAO";;
  limpar-dev) cmd_limpar_dev "$ARG_SESSAO" "$ARG_ITENS";;
  quarentena) cmd_quarentena "$ARG_SESSAO" "$ARG_ITENS";;
  remover-agente) cmd_remover_agente "$ARG_SESSAO" "$ARG_ITENS";;
  concluir) cmd_concluir "$ARG_SESSAO";;
  listar-quarentena) cmd_listar_quarentena;;
  restaurar) cmd_restaurar "$ARG_POS" "$ARG_DESTINO";;
  apagar-de-vez) cmd_apagar_de_vez "$ARG_POS" "$ARG_ANTES";;
  *) uso; exit 2;;
esac
