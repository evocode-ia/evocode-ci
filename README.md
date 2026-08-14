# evocode-ci

Workflows reutilizáveis de CI usados pelos projetos da **EvoCODE IA®** e da **NextHop Solutions®**.

Este repositório é público por um motivo prático: workflow reutilizável hospedado em repositório privado só pode ser chamado por repositórios da **mesma organização**, e os projetos que consomem esta pipeline estão espalhados por três orgs. Aqui não há segredo, credencial nem endereço interno — só passos de build.

## Uso

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

## Entradas

| Entrada | Padrão | O que faz |
|---|---|---|
| `php-version` | — (obrigatória) | Versão do PHP. Use a que o `composer.lock` exige, não a declarada no `composer.json`. |
| `node-version` | `24` | Versão do Node. |
| `working-directory` | `.` | Diretório do Laravel, quando ele não fica na raiz do repositório. |
| `php-extensions` | vazio | Extensões extras, separadas por vírgula. |
| `phpstan` | `true` | Roda o PHPStan no job de qualidade. |
| `frontend` | `true` | Instala e builda o frontend antes dos testes. |
| `frontend-lint` | `false` | Roda `npm run lint` no job de qualidade. |
| `composer-audit` | `true` | Roda `composer audit` no job de qualidade. |
| `sqlite-file` | `true` | Cria `database/database.sqlite` antes dos testes. |

## Por que a pipeline é assim

Cada decisão veio de uma pipeline vermelha, não de preferência:

- **`coverage: none`** — xdebug sem ninguém consumindo cobertura multiplica o tempo da suíte e o overhead de memória derruba as maiores. Pior: a proteção de loop infinito do xdebug mascara recursão real no código, que só aparece quando ele sai.
- **Versão do PHP vinda do `composer.lock`** — `composer.json` pode declarar um mínimo que o lock não satisfaz; nesse caso o `composer install` nem completa.
- **`.env` → `key:generate` → sqlite → ziggy → build → testes** — o ziggy é gerado pelo artisan e não é versionado, e o build do frontend depende dele.
- **Build do frontend antes dos testes** — suíte que renderiza Inertia precisa do manifest do Vite; sem ele, toda requisição HTTP responde 500.
- **`memory_limit=1G` no `phpunit.xml` do projeto** — não é entrada daqui, mas faz parte do padrão.

## Versionamento

A tag `v1` aponta para a versão estável. Consuma sempre por tag, nunca por `@main`.
