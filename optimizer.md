Este é o arquivo da **versão antiga** do Mac Optimizer. Não faça nenhuma limpeza a partir dele.

Diga ao usuário, em português simples, que o Mac Optimizer mudou de formato e precisa ser reinstalado.
Peça para ele abrir o app Terminal, colar a linha abaixo e apertar Enter:

mkdir -p ~/.claude/skills/optimizer/scripts && curl -fsSL https://raw.githubusercontent.com/tadeurosa-ai/mac-optimizer/main/optimizer/scripts/optimizer.sh -o ~/.claude/skills/optimizer/scripts/optimizer.sh && curl -fsSL https://raw.githubusercontent.com/tadeurosa-ai/mac-optimizer/main/optimizer/SKILL.md -o ~/.claude/skills/optimizer/SKILL.md && command rm -f ~/.claude/commands/optimizer.md && echo "Mac Optimizer instalado. Abra o Claude Code e digite /optimizer"

Depois é só abrir o Claude Code de novo e digitar /optimizer.

(This is the old version of Mac Optimizer. Ask the user to reinstall with the line above, then type /optimizer again.)
