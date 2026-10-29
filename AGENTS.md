# evocode-ci

> **Camada institucional**: `nexthop-dev-standards` — validado contra a **vX.Y.Z**.

Workflows reutilizáveis (`workflow_call`) de GitHub Actions que os projetos Laravel e as imagens
Docker da EvoCODE IA® e da NextHop Solutions® consomem por `uses:` (`README.md`, *Sobre*).

<!-- nexthop:inicio · gerado da camada v9.5.0 por tools/sync-agents-md.mjs — não edite dentro do bloco -->

## Camada NextHop — contrato de entrada

Este projeto segue a camada institucional `nexthop-dev-standards`. Este bloco é gerado por ela:
não edite dentro dele, porque o texto do projeto fica fora. O porquê de cada regra está no
`docs/_meta/delegacao.md` da camada.

**A regra:** faça o trabalho, e no menor tempo. Chame um especialista quando o julgamento dele
valer o que custa — checklist de domínio que você não tem, ou revisão independente como
controle — e reparta em subagentes paralelos quando a tarefa se divide em partes
independentes. Não há designação obrigatória, e agente não compra o que a máquina já mede.

### Onde está o resto da camada

| Ferramenta | Como chegar |
|---|---|
| Claude Code | plugin `nexthop@nexthop`: comandos `/nexthop:<intenção>`, especialistas `nexthop:<nome>` |
| Codex, Copilot, Cursor, Gemini | skills em `~/.agents/skills`: comece por `nexthop-camada`; cada intenção é `nexthop-comando-<intenção>` |

Intenções: `gates` (primeiro, sem agente), `entrega`, `revisar`, `visual`, `design`, `marca`,
`seguranca`, `investigar` e `soltar`. Sem a camada instalada, valem este bloco e a CI do projeto.

### A máquina antes do agente

Rode a intenção `gates` antes de pedir julgamento: classe de risco do diff (`classify-diff`),
suíte do projeto e varredura de segredo (`audit-scan`). Classe C é recomendação medida de
revisão de segurança, não ordem. Pedido vago, relato ("deu erro"), solução pronta sem o problema
ou sem critério de aceite vai primeiro ao `analista-requisitos`; tarefa grande que cruza
domínios, ao `arquiteto-software`.

### Velocidade: paralelo, sem sobreposição

Velocidade é prioridade: o que não depende de outro resultado roda ao mesmo tempo.

- **Reparta antes de executar** e dispare a leva inteira de uma vez: várias chamadas `Agent` na
  mesma mensagem (Claude Code), agentes em paralelo (Codex) ou comandos em segundo plano.
- **Cada designação nomeia os caminhos que escreve**, sem cruzamento; arquivo comum (lock,
  `CHANGELOG`, rota, índice) tem um dono só ou fica para a sessão principal, depois da leva.
- **Só espera quem depende.** Leitura e pesquisa podem se sobrepor; escrita, nunca. Subagente
  não abre subagente: quem reparte e integra é a sessão principal.

### Obrigatórios

Cada um existe porque um incidente aconteceu.

- **Commit, push, tag e instalação de dependência são da sessão principal**, por decisão humana
  para aquela execução e aquele escopo. Subagente não faz nenhum dos quatro.
- **Fronteira de repositório:** trabalhe só no projeto em que a sessão abriu; os outros são
  leitura. Escrever em outro exige pedido que nomeie o projeto e a ação.
- **Duas sessões no mesmo repositório usam worktrees próprios.** Nunca `stash`, `checkout`,
  `reset` ou `restore` em árvore que não é sua.
- **Nunca `rm -rf` em diretório compartilhado** (raiz de scratchpad, `/tmp`): remova só o que
  você criou, por caminho nomeado.
- **Dois agentes da mesma leva nunca editam o mesmo arquivo**, e cada um trabalha na própria
  árvore.
- **Documentação da versão instalada antes de escrever contra API de framework:** Laravel e
  pacote PHP pelo `SearchDocs` do Boost; o resto pelo Context7. Sem resposta, escreva "não
  confirmado na documentação".
- **Decisão de negócio, custo, risco jurídico ou fiscal volta ao humano.**

### Stack

A camada presume Laravel + Inertia + React + Tailwind v4. Confira `composer.json` e
`package.json` antes de aplicar prescrição técnica dela; fora desse stack, valem só as partes
agnósticas (segurança OWASP, acessibilidade, SEO, i18n, performance, git e revisão). Camada
institucional própria do repositório vence esta.

### Fatos deste projeto

Stack, portas, locales e tenancy variam. Leia o overlay do projeto quando existir: no Claude
Code ele entra sozinho; nas outras ferramentas, pela skill `nexthop-projeto-<slug>`.
Sem overlay, não bloqueia: levante do checkout (manifests, locks, CI, `docs/`) e registre de
onde veio cada fato.

### Este arquivo

É o único arquivo de instrução do projeto: sem `CLAUDE.md` (exceção: `@AGENTS.md` mais instrução
só do Claude), sem `@import`, até 200 linhas e 16 KiB. Fora deste bloco, o texto é do projeto.
A linha de versão validada é escrita por humano, no PR em que o projeto for conferido contra a
camada nova. Em conflito, regra da camada vence regra do projeto; para fato (versão, porta),
vale o que foi medido no projeto; exceção a regra mora em ADR.

<!-- nexthop:fim -->

## Produto

| Workflow | O que faz (fonte: `README.md`, *Workflows disponíveis*) |
|---|---|
| `.github/workflows/laravel-ci.yml` | Pint, PHPStan com gate de baseline, `composer audit`, build de frontend (Vite/Ziggy) e Pest, em sqlite ou MySQL de serviço |
| `.github/workflows/publish-image.yml` | Publica imagem no Docker Hub com pré-voo de credenciais e, opcionalmente, a descrição do repositório a partir do README |

Entradas e padrões de cada um: tabelas do `README.md`, seção *Como usar*.

## Comandos

Não há suíte própria: o `.yml` é o artefato. Valide pelo consumo real, com um PR num projeto
consumidor apontando para a branch (`uses: evocode-ia/evocode-ci/.github/workflows/laravel-ci.yml@<branch>`)
antes de mover a tag `v1` (`README.md`, *Qualidade*).

## Fatos deste projeto

- **Repositório público** de propósito: workflow reutilizável em repositório privado só é chamável
  pela mesma organização, e os consumidores estão em três orgs. Aqui não entra segredo, credencial
  nem endereço interno (`README.md`, *Sobre*).
- **Versionamento**: a tag `v1` aponta para a versão estável; consumo sempre por tag, nunca `@main`
  (`README.md`, *Versionamento*).
- Fora do stack Laravel + Inertia da camada: valem só as partes agnósticas. Sem overlay deste
  projeto na camada; fatos levantados do checkout.

## Invariantes e armadilhas

Cada uma veio de pipeline vermelha ou incidente; o porquê passo a passo está nos comentários dos
`.yml` (`README.md`, *Decisões de design*).

- **`laravel-ci.yml`**: `coverage: none` por padrão (xdebug multiplica o tempo e mascara recursão);
  `pcov` quando `coverage: true`; versão do PHP vinda do `composer.lock`, não do `composer.json`;
  ordem `.env` → `key:generate` → sqlite → Ziggy → build → testes, com build antes dos testes
  (Inertia sem manifest do Vite responde 500); gate que reprova crescimento do `phpstan-baseline.neon`.
- **`publish-image.yml`**: usuário do Docker Hub é `input` (`vars.DOCKERHUB_USERNAME`), não secret;
  só `DOCKERHUB_TOKEN` é segredo. O pré-voo contra `auth.docker.io` dá erro legível antes do login.
  Actions fixadas por SHA de 40 caracteres, nunca por tag de major.
- **Mudança aqui atinge todo consumidor de `@v1`** ao mover a tag.
