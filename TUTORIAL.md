# Mac Optimizer — Guia de Instalação Completo

**Para quem é isso:** usuários do Claude Pro ou Max que querem liberar espaço no Mac sem saber programar.

**Tempo:** 5 minutos na primeira vez. Depois é só digitar `/optimizer`.

---

## Pré-requisito: instalar o Claude Code

Claude Code é uma versão do Claude que roda no terminal e consegue executar ações no seu Mac — como escanear e limpar arquivos. É gratuito para quem tem plano Pro ou Max.

### Passo 1 — Instalar o Node.js

O Node.js é necessário para instalar o Claude Code. Abra o Terminal:

- Pressione `Cmd + Espaço`
- Digite **Terminal**
- Pressione Enter

Cole o comando abaixo e pressione Enter:

```bash
brew install node
```

> Se aparecer "command not found: brew", instale o Homebrew primeiro:
> ```bash
> /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
> ```
> Depois repita o `brew install node`.

---

### Passo 2 — Instalar o Claude Code

```bash
npm install -g @anthropic-ai/claude-code
```

Aguarde terminar. Pode demorar 1–2 minutos.

---

### Passo 3 — Fazer login no Claude Code

```bash
claude
```

Na primeira vez vai pedir para fazer login com sua conta Claude (a mesma do site). Siga as instruções na tela.

---

## Instalar o Mac Optimizer

Com o Claude Code instalado, cole este comando no Terminal:

```bash
mkdir -p ~/.claude/commands && curl -fsSL https://raw.githubusercontent.com/tadeurosa-ai/mac-optimizer/main/optimizer.md -o ~/.claude/commands/optimizer.md && echo "✓ /optimizer instalado"
```

Você verá:
```
✓ /optimizer instalado
```

**Só precisa fazer isso uma vez.** O comando fica salvo para sempre.

---

## Usar o Mac Optimizer

Abra o Claude Code no terminal:

```bash
claude
```

Dentro da sessão, digite:

```
/optimizer
```

Claude vai escanear seu Mac e conduzir tudo. Você só responde as perguntas em português.

---

## O que esperar

```
Claude: Escaneei seu Mac. Encontrei 4.2GB para liberar:

  ✓ Caches: 3.8GB — sistema reconstrói automaticamente
  ✓ Instaladores antigos: 400MB — apps já instalados

  Posso deletar tudo agora? (s/n)

Você: s

Claude: ✓ 4.2GB liberados com sucesso.
```

---

## Dúvidas frequentes

**Preciso pagar algo além do Claude Pro/Max?**
Não. O plugin é gratuito.

**É seguro?**
Sim. Claude só deleta com sua confirmação. Itens duvidosos são perguntados antes.

**Funciona toda vez?**
Sim. Após instalar, basta digitar `/optimizer` em qualquer sessão do Claude Code.

**Como desinstalar o plugin:**
```bash
rm ~/.claude/commands/optimizer.md
```

---

Se funcionou, deixa uma estrela no GitHub. Ajuda o projeto a chegar em mais gente.

**github.com/tadeurosa-ai/mac-optimizer**
