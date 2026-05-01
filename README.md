# Mac Optimizer — Claude Code Plugin

Libera espaço no seu Mac conversando com Claude. Sem comandos, sem configuração.

---

## Instalação

Cole no terminal e pressione Enter:

```bash
mkdir -p ~/.claude/commands && curl -fsSL https://raw.githubusercontent.com/tadeurosa-ai/mac-optimizer/main/optimizer.md -o ~/.claude/commands/optimizer.md && echo "✓ /optimizer instalado"
```

---

## Como usar

Abra o Claude Code e digite:

```
/optimizer
```

Pronto. Claude escaneia, pergunta, você responde. Nada mais.

---

## O que faz

- Escaneia caches do sistema (`~/Library/Caches`)
- Identifica instaladores `.dmg` e `.pkg` já desnecessários
- Detecta pastas Application Support de apps removidos
- Analisa LaunchAgents e daemons desnecessários
- Identifica snapshots locais do Time Machine
- Pergunta antes de deletar qualquer coisa duvidosa
- Quarentena de 30 dias — recuperável se mudar de ideia
- Executa a limpeza com sua aprovação

## Requisitos

- macOS 12+
- Claude Code com plano Pro ou Max

---

## Resultados reais

| Sessão | Espaço liberado |
|--------|----------------|
| Teste 1 (17/04/2026) | 2.6GB |

---

Se funcionou, deixa uma estrela. Ajuda o projeto a chegar em mais gente.
