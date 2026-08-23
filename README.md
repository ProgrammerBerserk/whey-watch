# whey-watch

Vigia preços de whey protein em lojas portuguesas e avisa quando há promoção **a sério**.
Corre no GitHub Actions, manda alertas para um grupo de Telegram e publica uma página
sempre actual — sem ninguém precisar do PC ligado.

```
Loja      Produto                             Preco    EUR/100gP Stock      MinVisto Obs Alerta
MyProtein MyProtein Impact Whey Protein (1kg)    23,67   2,89    OutOfStock 23,67      3
Fitnis    7 Nutrition Whey Protein 80 (2kg)      48,99   3,14    OutOfStock 48,99      4
Zumub     Zumub Whey Protein Fusion (4kg)        96,97   3,63    InStock    96,97      3
Zumub     Zumub 100% Whey Concentrate (2kg)      64,98   4,56    InStock    69,50      4 minimo historico (antes 69,50 EUR)
```

## Três decisões de desenho que interessa conhecer

**1. O alerta ignora a percentagem de desconto anunciada pela loja.**
Várias mantêm um "preço de tabela" permanentemente inflacionado — a Zumub publica o
concentrado de 500 g a 19,96 € contra uma tabela de 34,99 €, ou seja está *sempre* a
-43%. Alertar sobre isso seria alertar todos os dias sobre nada. O único sinal fiável é
o preço cair abaixo do mínimo ou da mediana que o próprio script já observou. Daí o
`whey-watch.state.json`, e daí os primeiros dias serem de aprendizagem: `onNewLow`
precisa de 2 observações, `dropPctVsMedian` de 4.

**2. Compara em € por 100 g de proteína real.**
É a única métrica que torna comparáveis um concentrado a 71%, um isolado a 87% e
embalagens de 500 g a 5 kg: `preço ÷ (gramas × proteína% ÷ 100) × 100`.

**3. Uma promoção num sabor esgotado não é promoção.**
Quando uma loja publica uma oferta por sabor (a Bulk publica 79 numa página), as
ofertas são colapsadas por gramagem e fica a mais barata **que esteja em stock**.

## Montar na nuvem

### 1. Repositório

O repo tem de ser **público** se quiseres a página no GitHub Pages — Pages em repo
privado exige plano pago. Não há aqui nada sensível: os segredos do Telegram vivem
em GitHub Secrets, nunca no código.

```bash
gh repo create whey-watch --public --source=. --push
```

Ou à mão: cria o repo no GitHub e depois

```bash
git remote add origin https://github.com/<utilizador>/whey-watch.git
git push -u origin main
```

### 2. Diagnóstico primeiro

**Faz isto antes de confiares no agendamento.** Os sites vêem um IP de datacenter, e
alguns bloqueiam. Em *Actions → whey-watch → Run workflow*, liga a opção **doctor** e
corre. O resumo do job diz exactamente quais as lojas alcançáveis:

| Loja | HTTP | Ofertas | Nota |
|---|---|---|---|
| Fitnis | 200 | 1 | ok |
| Zumub | 200 | 5 | ok |
| Prozis | 429 | 0 | rate-limit: este IP está a ser travado |

Se muitas derem `403` ou `429`, o caminho da nuvem não serve para essas lojas e vale
mais correr no teu PC (ver *Correr localmente*).

### 3. Telegram

1. Cria o bot com o [@BotFather](https://t.me/botfather) (`/newbot`) e guarda o token
2. Cria o grupo e mete lá o bot e a outra pessoa
3. **No grupo, escreve uma mensagem que comece por `/`** — ex.: `/ola`
4. Corre:

```powershell
.\setup-telegram.ps1
```

O passo 3 não é capricho. Os bots do Telegram têm *privacy mode* ligado por omissão e
**não recebem mensagens normais de grupo**; sem uma mensagem com `/` (ou a entrada do
bot no grupo) o `getUpdates` devolve lista vazia e não há como descobrir o `chat_id`.

O script pede o token de forma oculta, valida-o no `getMe`, lista as conversas
encontradas, manda uma mensagem de teste ao grupo escolhido e grava os dois secrets
via `gh` **por stdin** — para o token não ficar no histórico da shell nem visível na
lista de processos. Nunca o escreve em ficheiro.

Com `-NoSecrets` só descobre e mostra o `chat_id`, sem tocar no GitHub.

Se preferires à mão, os secrets são estes, em *Settings → Secrets and variables →
Actions*:

| Secret | Valor |
|---|---|
| `TELEGRAM_BOT_TOKEN` | o token do BotFather |
| `TELEGRAM_CHAT_ID` | o id do grupo (negativo, ex.: `-1001234567890`) |

O script activa o Telegram só pela presença dos segredos — localmente, sem eles
definidos, não tenta enviar nada.

### 4. Página

*Settings → Pages → Source: Deploy from a branch*, ramo `main`, pasta `/docs`.
Fica em `https://<utilizador>.github.io/whey-watch/`. É esse o link a partilhar.

### 5. Cadência

Está a cada 3 horas (`cron: '7 */3 * * *'`). Não vale a pena descer: as lojas não
mexem nos preços de hora a hora e há limites de pedidos a respeitar.

> O GitHub suspende workflows agendados em repos sem actividade há 60 dias. Como cada
> ronda faz commit do histórico, isto mantém-se vivo sozinho.

## Correr localmente

```powershell
.\whey-watch.ps1 -Report          # tabela, sem gravar estado nem notificar
.\whey-watch.ps1                  # ronda a sério: grava histórico e notifica
.\whey-watch.ps1 -Doctor          # que lojas respondem a este IP
.\whey-watch.ps1 -Only zumub      # só os alvos cujo id contenha "zumub"
.\whey-watch.ps1 -Discover        # SKUs em bruto, para preencher skuGrams
.\whey-watch.ps1 -Force           # notifica sem esperar alteração (testar toast)
.\build-page.ps1                  # gera docs/index.html a partir do status.json
```

Notificações toast do Windows funcionam sem configuração. Para agendar no teu PC em
vez da nuvem:

```powershell
.\install-task.ps1 -IntervalHours 3
.\install-task.ps1 -Uninstall
```

A tarefa corre só com sessão iniciada — exigência dos toasts, que precisam de sessão
interactiva.

O script corre em PowerShell 5.1 (Windows) e em PowerShell 7 (o runner Linux usa
`pwsh`). O toast é ignorado fora do Windows.

## Configurar alvos

```json
{
  "id": "fitnis-7n-whey80",
  "store": "Fitnis",
  "name": "7 Nutrition Whey Protein 80",
  "url": "https://fitnis.pt/pt/proteinas/1178-...html",
  "parser": "jsonld",
  "proteinPer100g": 78,
  "defaultGrams": 2000,
  "alert": {
    "onNewLow": true,
    "maxEurPer100gProtein": 3.05,
    "dropPctVsMedian": 7,
    "onBackInStock": true
  }
}
```

| Campo | Para que serve |
|---|---|
| `parser` | `jsonld` (Fitnis, Bulk, MyProtein, EU Nutrition, Prozis) ou `microdata` (Zumub) |
| `proteinPer100g` | **tira-o do rótulo**, é o que faz a matemática ser honesta |
| `defaultGrams` | páginas de formato único |
| `skuGrams` | páginas multi-formato: mapa SKU → gramas (usa `-Discover`) |
| `gramsFromSkuRegex` | gramagem embutida no SKU (Bulk: `BPB-WPC8-CHOC-2500`) |
| `minGapSeconds` | intervalo mínimo entre pedidos ao domínio |
| `maxAttempts` | tentativas antes de desistir do alvo |
| `checkEveryHours` | não voltar a consultar antes disto, seja qual for a cadência |
| `residentialOnly` | loja que só responde a IPs residenciais: saltada quando corre em CI |

As gramagens também são detectadas a partir de `schema.org/weight` (o MyProtein
publica-as) ou do nome da variante, portanto muitas vezes não precisas de `skuGrams`.

### Regras de alerta

| Regra | Dispara quando | Precisa de |
|---|---|---|
| `onNewLow` | preço abaixo do mínimo já observado | ≥2 observações |
| `maxEurPer100gProtein` | €/100 g de proteína dentro do teu limite | gramagem conhecida |
| `dropPctVsMedian` | preço ≥X% abaixo da mediana do histórico | ≥4 observações |
| `onBackInStock` | estava esgotado, voltou | 1 observação anterior |

Todas exigem produto **em stock**. `alertCooldownHours` (20) impede o mesmo alerta ao
mesmo preço de repetir a cada ronda.

## Acrescentar uma loja

1. Confirma que serve preços em HTML, não por JavaScript:

   ```powershell
   $c = (Invoke-WebRequest -Uri "URL" -UseBasicParsing -UserAgent "Mozilla/5.0").Content
   ([regex]::Matches($c,'application/ld\+json')).Count   # >0 -> parser "jsonld"
   ([regex]::Matches($c,'itemprop="price"')).Count       # >0 -> parser "microdata"
   ```

2. Acrescenta o alvo com `proteinPer100g` tirado do rótulo.
3. `.\whey-watch.ps1 -Discover -Only <id>` e preenche `skuGrams` se preciso.
4. `.\whey-watch.ps1 -Report -Only <id>` para confirmar os números.

## Sobre a página

Auto-contida, sem dependências externas, telefone primeiro. A tabela é o produto:
barra de magnitude na coluna do €/100 g de proteína e sparkline do histórico por linha.
Não há gráfico separado a duplicar a tabela.

O stock **não** é codificado por matiz. Um verde "em stock" ao lado de um laranja
"esgotado" dá uma separação de apenas 5,6 ΔE em protanopia — indistinguíveis para quem
tem daltonismo vermelho-verde. Esgotado fica em tinta apagada, com a palavra escrita e
o preço riscado; a única cor de status na página é o selo de promoção. A paleta que
sobra (azul de acento + verde de status) passa as seis verificações do validador nos
dois modos, claro e escuro.

## Limites conhecidos

**Três lojas só respondem a IPs residenciais** e estão marcadas `residentialOnly`:

| Loja | De casa | Da nuvem |
|---|---|---|
| EU Nutrition | 200 | `403` |
| Prozis | 200 nas primeiras consultas, depois `429` | `429` à primeira |

Na nuvem são saltadas de propósito — tentar não dá nada e as tentativas condenadas
sujavam o "N/M lojas responderam". **Consequência prática: no GitHub Actions estas
lojas não são vigiadas.** Se as quiseres a sério, tens de correr a tarefa local
(`install-task.ps1`) num PC com IP residencial. Se um dia deixarem de bloquear, tira
o campo do config.

O `-Doctor` sonda-as sempre, de propósito — é o único sítio onde queres saber o que
*este* IP alcança — mas anota `[esperado: residentialOnly]` para um 403 não ser lido
como avaria.

**A HSN não é vigiável e não vale a pena tentar.** A `hsnstore.pt` e a `hsnstore.eu`
devolvem `403` a qualquer pedido — até à homepage, com um conjunto completo de
cabeçalhos de browser. É um bloqueio no edge que rejeita tudo o que não seja um
browser real. O KuantoKusta, que agregaria os preços dela, bloqueia da mesma forma.
Passar por isso exigiria falsificar impressão digital de browser, o que é frágil e é
evasão de detecção. Se quiseres os preços da HSN, é a olho no site.

**A Bulk Powders é a Bulk.** Mudou de nome em 2020; está no config como
`bulk-pure-whey`. Não a acrescentes outra vez.

**Nenhum site é acedido com browser headless.** Se alguma loja passar a renderizar
preços por JavaScript, o log escreve `nenhum preco extraido - o site pode ter mudado
de estrutura`. É esse o aviso de que um parser apodreceu — e aparece no resumo do job.

**As percentagens de proteína são responsabilidade tua.** Ficam no config e o script
confia nelas. Se uma marca reformular o produto, o €/100 g passa a mentir sem dar erro.

**Os preços não incluem portes.** Fitnis e Prozis oferecem; MyProtein e Bulk cobram.
Num carrinho de 50 € são uns 5 € que a tabela não mostra.
