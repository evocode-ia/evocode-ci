# ADR 0001: GitHub Actions com runners próprios

**Data:** 2026-11-05 · **Situação:** aceita

## Contexto

Os minutos dos runners do GitHub, principalmente de macOS e Windows, passaram a pesar no custo, e um problema de
cobrança parou o CI da organização. A diretriz é compilar em máquinas nossas e gastar o mínimo no GitHub.

## Decisão

Manter o GitHub Actions e rodar os jobs em runners próprios, em VMs Linux isoladas dentro de um servidor existente, com
um runner por VM.

## Alternativas

| Alternativa | Por que não |
|---|---|
| **Woodpecker CI** | Tira o CI da dependência da cobrança do GitHub, mas exige reescrever todos os workflows, manter um servidor de CI e expor um endpoint de webhook. Chegou a ser escrito e foi abandonado antes de instalar. Quem tem push também obteria os segredos do repositório: a troca não melhorava esse ponto |
| **Runner direto no servidor** | Um job teria acesso às credenciais de quem desenvolve na máquina |
| **Vários runners em uma VM** | Jobs simultâneos disputam portas de serviço (`3306:3306`) e o PHP global do `setup-php` |
| **Tornar este repositório privado** | Compartilhar workflow privado entre organizações exige conta Enterprise, e os consumidores estão em mais de uma |

## Consequências

- **O CI continua dependendo da cobrança do GitHub.** Um teste mostrou que, com o pagamento recusado, nem um job em
  runner próprio é criado.
- O servidor passa a concentrar desenvolvimento e builds, e a capacidade dele limita os dois.
- Reaproveitar o runner deixa um risco aberto: um job malicioso pode persistir na VM (ver
  [runners.md](../runners.md#segurança)).
- A taxa por minuto de runner próprio, anunciada e adiada pelo GitHub, pode voltar. Se isso ocorrer, reavalie.
