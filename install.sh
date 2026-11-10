#!/bin/bash
# ============================================================
#  Mac Optimizer — Instalador (para quem clonou o repositório)
#  Uso: bash install.sh
#  Instala a skill em ~/.claude/skills/optimizer/ e remove o comando
#  antigo ~/.claude/commands/optimizer.md (senão ficam dois /optimizer).
# ============================================================
set -eu

AQUI="$(cd "$(dirname "$0")" && pwd)"
ORIGEM="$AQUI/optimizer"
DESTINO="$HOME/.claude/skills/optimizer"
ANTIGO="$HOME/.claude/commands/optimizer.md"

if [ ! -f "$ORIGEM/SKILL.md" ] || [ ! -f "$ORIGEM/scripts/optimizer.sh" ]; then
  echo "Erro: arquivos da skill não encontrados em $ORIGEM"
  exit 1
fi

mkdir -p "$DESTINO/scripts"
cp "$ORIGEM/scripts/optimizer.sh" "$DESTINO/scripts/optimizer.sh"
cp "$ORIGEM/SKILL.md" "$DESTINO/SKILL.md"
echo "✓ Skill instalada em $DESTINO"

if [ -f "$ANTIGO" ]; then
  command rm -f "$ANTIGO"
  echo "✓ Comando antigo removido ($ANTIGO)"
fi

echo ""
echo "Pronto! Abra o Claude Code e digite /optimizer"
