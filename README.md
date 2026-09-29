<div align="center">

# evocode-ci

**Workflows reutilizáveis de CI/CD para os projetos Laravel e Docker da casa.**

Um produto **EvoCODE IA®**, da casa **NextHop Solutions®**

[![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-workflows_reutilizáveis-2088FF?style=flat-square&logo=githubactions&logoColor=white)](https://docs.github.com/actions/using-workflows/reusing-workflows)
[![Versão](https://img.shields.io/github/v/tag/evocode-ia/evocode-ci?style=flat-square&label=versão&color=2088FF)](https://github.com/evocode-ia/evocode-ci/tags)
[![Licença](https://img.shields.io/badge/licença-proprietária-6E7681?style=flat-square)](#licença)

</div>

---

## Sobre

Este repositório hospeda os workflows reutilizáveis (`workflow_call`) que os projetos Laravel e as imagens Docker da **EvoCODE IA®** e da **NextHop Solutions®** consomem via `uses:`.

É público por um motivo prático, não por escolha de exposição: um workflow reutilizável hospedado em repositório privado só pode ser chamado por repositórios da **mesma organização**, e os projetos que consomem esta pipeline estão espalhados por três orgs. Aqui não há segredo, credencial nem endereço interno — só passos de build.

## Workflows disponíveis

| Workflow | O que faz |
|---|---|
| [`laravel-ci.yml`](.github/workflows/laravel-ci.yml) | Pipeline de CI para projetos Laravel: Pint, PHPStan (com gate de baseline), `composer audit`, build de frontend (Vite/Ziggy) e testes com Pest — sqlite ou MySQL de serviço. |
| [`publish-image.yml`](.github/workflows/publish-image.yml) | Publica imagem no Docker Hub com pré-voo de credenciais (valida formato, não só presença) e, opcionalmente, atualiza a descrição do repositório no Docker Hub a partir do README. |

## Como usar

### `laravel-ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
    paths-ignore: ["**/*.md", "docs/**"]
  pull_request:
    branches: [main]
    paths-ignore: ["**/*.md", "docs/**"]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    uses: evocode-ia/evocode-ci/.github/workflows/laravel-ci.yml@v1
    with:
      php-version: "8.4"
```

Entradas principais (todas em [`laravel-ci.yml`](.github/workflows/laravel-ci.yml)):

| Entrada | Padrão | O que faz |
|---|---|---|
| `php-version` | — (obrigatória) | Versão do PHP. Use a que o `composer.lock` exige, não a declarada no `composer.json`. |
| `node-version` | `24` | Versão do Node. |
| `working-directory` | `.` | Diretório do Laravel, quando ele não fica na raiz do repositório. |
| `php-extensions` | vazio | Extensões extras do PHP, separadas por vírgula. |
| `phpstan` | `true` | Roda o PHPStan no job de qualidade. |
| `baseline-gate` | `true` | Falha o PR se o `phpstan-baseline.neon` crescer em relação à branch alvo. |
| `frontend` | `true` | Instala e builda o frontend antes dos testes. |
| `frontend-lint` | `false` | Roda `npm run lint` no job de qualidade. |
| `composer-audit` | `true` | Roda `composer audit` no job de qualidade. |
| `coverage` | `false` | Mede cobertura com pcov e publica o número no resumo do job. Sem gate por padrão — o objetivo é ter o número. |
| `coverage-min` | `0` | Piso de cobertura. O PR falha se cair abaixo dele. Sobe por catraca: nunca desce. |
| `sqlite-file` | `true` | Cria `database/database.sqlite` antes dos testes. |
| `mysql` | `false` | Sobe um MySQL de serviço para a suíte, em vez de sqlite. |
| `mysql-version` | `8.4` | Tag da imagem do MySQL de serviço. |
| `mysql-database` | `testing` | Nome do banco criado no serviço. Tem que bater com o `DB_DATABASE` do `phpunit.xml`. |

### `publish-image.yml`

```yaml
jobs:
  publish:
    uses: evocode-ia/evocode-ci/.github/workflows/publish-image.yml@v1
    with:
      tags: |
        meuusuario/minhaimagem:latest
        meuusuario/minhaimagem:${{ github.sha }}
      username: ${{ vars.DOCKERHUB_USERNAME }}
    secrets:
      DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
```

`username` vem de `vars.DOCKERHUB_USERNAME` (variável do repositório, **não** secret): é o namespace público, já escrito em claro na tag da imagem — guardá-lo como secret só mascarava o log e escondia erro de digitação. Só `DOCKERHUB_TOKEN` é segredo.

Entradas principais (todas em [`publish-image.yml`](.github/workflows/publish-image.yml)):

| Entrada | Padrão | O que faz |
|---|---|---|
| `tags` | — (obrigatória) | Tags completas (`repo:tag`), uma por linha. |
| `username` | — (obrigatória) | Usuário do Docker Hub. Passe `vars.DOCKERHUB_USERNAME`. |
| `context` | `.` | Contexto do build. |
| `file` | `./Dockerfile` | Caminho do Dockerfile. |
| `platforms` | `linux/amd64` | Plataformas do build. Declarado, não herdado do runner. |
| `labels` | vazio | Labels OCI. |
| `target` | vazio | Estágio do Dockerfile a construir, em build multi-stage. |
| `description-repository` | vazio | `namespace/repo` cuja descrição no Docker Hub deve ser atualizada a partir do README. Vazio desliga o passo. |
| `short-description` | vazio | Descrição curta do repositório no Docker Hub. |
| `readme-filepath` | `./README.md` | Caminho do README publicado como descrição longa. |
| `cache-scope` | `publish-image` | Escopo do cache `type=gha`, isolado do namespace default. |

Secret obrigatório: `DOCKERHUB_TOKEN`.

## Decisões de design

Cada decisão embutida nos workflows veio de uma pipeline vermelha ou de um incidente real, não de preferência — os comentários nos próprios arquivos `.yml` documentam o porquê passo a passo. Resumo:

**`laravel-ci.yml`**
- **`coverage: none` por padrão** — xdebug sem ninguém consumindo cobertura multiplica o tempo da suíte, e o overhead de memória derruba as maiores. Pior: a proteção de loop infinito do xdebug mascara recursão real, que só aparece quando ele sai.
- **Versão do PHP vinda do `composer.lock`** — `composer.json` pode declarar um mínimo que o lock não satisfaz; nesse caso o `composer install` nem completa.
- **`.env` → `key:generate` → sqlite → Ziggy → build → testes** — o Ziggy é gerado pelo artisan e não é versionado, e o build do frontend depende dele.
- **Build do frontend antes dos testes** — suíte que renderiza Inertia precisa do manifest do Vite; sem ele, toda requisição HTTP responde 500.
- **`pcov` em vez de `xdebug` quando `coverage: true`** — ordens de grandeza mais barato, sem o custo que faz o xdebug ficar proibido no resto do tempo.
- **Gate do baseline do PHPStan** — "o baseline só encolhe" só é regra se alguém verificar; sem o gate, basta regenerar o arquivo para esconder um erro novo.

**`publish-image.yml`**
- **Usuário do Docker Hub como `input`, não `secret`** — é o namespace público, já em claro na tag da imagem. Guardá-lo como secret não protegia nada e custava a visibilidade que teria encurtado o diagnóstico de um incidente real (kairo, 25/08/2026: quatro dias sem publicar imagem porque o campo de usuário guardava um token, e a checagem local só testava se o secret estava vazio).
- **Pré-voo contra `auth.docker.io`** — `docker/login-action` traduz qualquer problema para "malformed HTTP Authorization header", mensagem que não menciona credencial. O pré-voo devolve um código HTTP legível antes do login acontecer.
- **Actions fixadas por SHA de 40 caracteres, não por major** — este é o job que autentica no Docker Hub e roda com `push: true`; tag de major é ponteiro móvel.

## Qualidade

Este repositório não tem suíte de testes própria: o conteúdo dos arquivos `.yml` **é** o artefato, e cada mudança é validada pelo consumo real — abra um PR num projeto consumidor apontando para a branch (`uses: evocode-ia/evocode-ci/.github/workflows/laravel-ci.yml@<branch>`) antes de mover a tag `v1`.

## Versionamento

A tag `v1` aponta para a versão estável. Consuma sempre por tag, nunca por `@main`.

## Licença

Software proprietário. © 2026 EvoCODE IA® — todos os direitos reservados.
Uso, cópia ou distribuição apenas com autorização expressa da
NextHop Solutions®.
