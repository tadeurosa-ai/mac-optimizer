Execute uma limpeza inteligente de disco no Mac do usuário. Siga exatamente este fluxo:

## Passo 1 — Scan de caches

Execute via Bash tool:
```bash
du -sh ~/Library/Caches/* 2>/dev/null | sort -rh | head -15
```

Calcule o total em MB:
```bash
du -sm ~/Library/Caches/* 2>/dev/null | awk '{sum+=$1} END {print sum"MB"}'
```

## Passo 2 — Scan de instaladores

Execute via Bash tool:
```bash
find ~/Downloads -maxdepth 2 \( -name "*.dmg" -o -name "*.pkg" \) 2>/dev/null | while read f; do
  name=$(basename "$f")
  size=$(du -sm "$f" 2>/dev/null | awk '{print $1}')
  clean=$(echo "$name" | sed 's/\.dmg$//' | sed 's/\.pkg$//' | sed 's/[-_ ][0-9].*//' | awk -F'[-_ ]' '{print $1}')
  installed=$(find /Applications -maxdepth 1 -iname "*${clean}*" 2>/dev/null | head -1)
  if [ -n "$installed" ]; then
    echo "SAFE|${f}|${name}|${size}MB"
  else
    echo "AMBIGUOUS|${f}|${name}|${size}MB"
  fi
done
```

## Passo 3 — Verificar espaço em disco

```bash
df -h / | tail -1 | awk '{print "Usado: "$3" | Livre: "$4" | "$5" cheio"}'
```

## Passo 4 — Apresentar ao usuário

Com base nos dados coletados, apresente em português de forma amigável:

```
Escaneei seu Mac. Encontrei X.XGB para liberar:

✓ Caches: X.XGB (15 pastas — sistema reconstrói automaticamente)
✓ Instaladores seguros: XMB (apps já instalados)
? Instaladores ambíguos: X item(s) — preciso de uma resposta antes

[se houver ambíguos]
Tenho uma dúvida: NomeDoArquivo.dmg (XMB) — você ainda usa esse app?
```

Aguarde resposta do usuário para itens ambíguos antes de continuar.

## Passo 5 — Confirmar

Após resolver ambíguos, mostre resumo e peça confirmação:
```
Posso deletar X.XGB agora. Confirma? (s/n)
```

## Passo 6 — Executar limpeza

Após confirmação, execute via Bash tool:

**Deletar caches:**
```bash
find ~/Library/Caches -maxdepth 1 -mindepth 1 2>/dev/null | while read d; do
  size=$(du -sm "$d" 2>/dev/null | awk '{print $1}')
  rm -rf "$d" 2>/dev/null && echo "✓ $(basename $d) — ${size}MB"
done
echo "Caches limpos."
```

**Deletar instaladores seguros:**
```bash
find ~/Downloads -maxdepth 2 \( -name "*.dmg" -o -name "*.pkg" \) 2>/dev/null | while read f; do
  name=$(basename "$f")
  clean=$(echo "$name" | sed 's/\.dmg$//' | sed 's/\.pkg$//' | sed 's/[-_ ][0-9].*//' | awk -F'[-_ ]' '{print $1}')
  installed=$(find /Applications -maxdepth 1 -iname "*${clean}*" 2>/dev/null | head -1)
  if [ -n "$installed" ]; then
    size=$(du -sm "$f" 2>/dev/null | awk '{print $1}')
    rm -f "$f" 2>/dev/null && echo "✓ ${name} — ${size}MB"
  fi
done
```

**Para cada item ambíguo aprovado pelo usuário:**
```bash
rm -f "/caminho/completo/do/arquivo"
```

## Passo 7 — Resultado final

Informe o total liberado com uma mensagem positiva. Mencione que a versão PRO analisa também Application Support órfãos, LaunchAgents desnecessários e snapshots do Time Machine.

---
**Regras importantes:**
- Nunca deletar sem confirmação explícita do usuário
- Máximo 3 perguntas sobre itens ambíguos (versão free)
- Responder sempre em português
- Não exibir os comandos bash ao usuário — só os resultados
