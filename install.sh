#!/usr/bin/env bash
# ============================================================
#  Mac Optimizer FREE — Instalador
#  Uso: bash install.sh
#  Após instalar: abra Claude Code e digite /optimizer
# ============================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}${BLUE}Mac Optimizer FREE — Instalando...${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD_SRC="$SCRIPT_DIR/optimizer.md"
CMD_DST="$HOME/.claude/commands/optimizer.md"

if [ ! -f "$CMD_SRC" ]; then
  echo -e "${RED}Erro: optimizer.md não encontrado em $SCRIPT_DIR${NC}"
  exit 1
fi

mkdir -p "$HOME/.claude/commands"
cp "$CMD_SRC" "$CMD_DST"

echo -e "  ${GREEN}✓${NC}  Comando /optimizer instalado"
echo ""
echo -e "${BOLD}${GREEN}Pronto!${NC}"
echo ""
echo -e "  Abra o ${BOLD}Claude Code${NC} e digite:"
echo ""
echo -e "      ${BOLD}/optimizer${NC}"
echo ""
echo -e "  Claude cuida do resto. Você só responde as perguntas."
echo ""
