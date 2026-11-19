# Amazon Profit Manager — banco de dados na nuvem (Supabase / PostgreSQL)

Esta pasta traz a **camada de banco de dados**: esquema, segurança por usuário, auditoria, cálculo de lucro,
recebimento de compras com custo médio, importação dos seus dados atuais e testes.
**O frontend ainda não está conectado ao banco** (veja "Limites").

## 1. Criar o projeto (você faz, ~10 min)
1. supabase.com > New project: nome `amazon-profit-manager`, senha do banco gerada (guarde no gerenciador de senhas; não compartilhe), região **South America (São Paulo)**.
2. Opções de segurança do formulário: pode deixar "Enable Data API" ligado; **"Automatically expose new tables" pode ficar desligado** (o `0003_grants.sql` dá as permissões certas) e **"Enable automatic RLS" ligado** (reforço extra).
3. **Authentication > Providers > Email**: ligado, com **Confirm email**. **URL Configuration**: Site URL do app. Senha mínima de 10 caracteres.
4. **SQL Editor**: execute, nesta ordem, os 3 arquivos de `supabase/migrations/` (0001, 0002, 0003).
5. Crie sua conta (Authentication > Users > Add user, ou pelo cadastro do app, quando existir).

## 2. Trazer seus dados atuais
1. No aplicativo atual, página **Backup** > **Copiar backup atual**; salve o texto em `backup.json`.
2. `npm install` e depois:
   `SUPABASE_URL=... SUPABASE_ANON_KEY=... APM_EMAIL=... APM_PASSWORD=... node scripts/import-backup.mjs backup.json`
3. Confira os números impressos contra o aplicativo. A importação é idempotente e **nunca sobrescreve** registros.

## 3. O que o banco garante
| Regra | Como |
|---|---|
| Cada conta vê só os próprios dados | RLS em todas as tabelas + chaves compostas `(user_id, id)` |
| Dinheiro sem erro de ponto flutuante | `numeric(14,2)` e `numeric(14,4)` para custos unitários |
| Pedido duplicado impossível | índice único por conta, ignorando espaços e maiúsculas |
| Venda baixa estoque uma única vez | gatilho + índice único `(conta, produto, pedido, tipo)` |
| Estoque é livro só de acréscimo | movimentações não podem ser editadas/excluídas diretamente |
| Compra recebida é imutável | só cabeçalho muda; não exclui nem cancela; compras nunca são excluídas |
| Produto com histórico não é excluído | `ON DELETE RESTRICT`; use `archived` |
| Custo real e custo médio | `receive_purchase(id)`: rateio em centavos (por valor ou quantidade), resto no último item, custo médio ponderado, em uma transação |
| Trilha de auditoria | gatilhos gravam INSERT/UPDATE/DELETE em `audit_log` (leitura própria; ninguém apaga) |
| Lucro por pedido | visão `order_results` (mesma fórmula do app, incluindo devoluções) |
| Sem login, sem acesso | papel `anon` sem permissões; só `authenticated` acessa, filtrado por RLS |

### Fórmulas
- Receita líquida = preço × qtd − descontos − reembolso.
- Custo vendido = (custo unitário + frete de compra) × qtd (congelado na venda; não muda retroativamente).
- Comissão = % × receita após descontos + valor fixo × qtd. Imposto = % × receita após descontos.
- Lucro = receita após descontos − (custo vendido + comissão + tarifa logística + frete do vendedor + imposto + embalagem + publicidade + outros) − reembolso + taxas devolvidas − custo extra de devolução + custo recuperado (se revendável e voltou ao estoque).
- Arredondamento: cada parcela e o lucro em 2 casas; custo unitário real em 4 casas.

## 4. Testes executados (PostgreSQL real via PGlite): `npm test`
- `run-tests.mjs`: 39 verificações (rateio e custo real de R$ 205,01, custo médio ponderado, recebimento único, imutabilidade, NF duplicada, lucro R$ 54,00 e R$ 44,00 com devolução, estoque, centavos, constraints, auditoria, **isolamento entre usuários**, usuário sem login e papel anon).
- `parity.mjs`: 8 verificações com 300 vendas e 40 compras aleatórias importadas do formato do app: lucro idêntico ao centavo em 296/300 (os outros 4 diferem em 1 centavo: o app usa ponto flutuante, o banco usa decimal exato; **o banco é a referência**), rateio idêntico em 102/102 itens, importação idempotente.

## 5. Backups e restauração
- Plano **Pro**: backups diários automáticos (Point-in-Time Recovery é add-on pago). No plano **Free não há backup automático**.
- Em qualquer plano, agende um dump (ex.: cron semanal): `pg_dump "$DATABASE_URL" -Fc -f apm-$(date +%F).dump`
- Restauração: `pg_restore -d "$NOVO_DATABASE_URL" --clean apm-AAAA-MM-DD.dump`. **Faça um ensaio num projeto vazio antes de depender; não pude testar isso com um Supabase real.**

## 6. Limites
- **Frontend**: o app publicado no claude.ai não consegue falar com o Supabase (a hospedagem bloqueia requisições a outros domínios). Usar o banco exige reconstruir o app como projeto Next.js na Vercel sobre este esquema (próxima fase). Até lá, os dados do app atual ficam só no navegador: faça backup.
- **Login por e-mail/senha**: recursos do Supabase Auth (passos acima); a tela de login ainda será construída.
- **Amazon SP-API**: não implementada (depende de credenciais LWA e servidor). `orders.source = 'SPAPI'` e `payouts` já existem para receber esses dados.
- `import_backup` e o script foram testados com PostgreSQL local, **não** contra um projeto Supabase real.
