# ADR 0001: GitHub Actions com runners próprios

**Data:** 2026-11-05 · **Situação:** aceita

## Contexto

Os minutos dos runners do GitHub, principalmente de macOS e Windows, passaram a pesar no custo, e um problema de
cobrança parou o CI da organização. A diretriz é compilar em máquinas nossas e gastar o mínimo no GitHub.

## Decisão

Manter o GitHub Actions e rodar os jobs em runners próprios, em VMs Linux isoladas dentro de um servidor existente. Cada
job roda em uma VM nova, criada de uma imagem somente leitura e descartada ao final.

## Alternativas

| Alternativa | Por que não |
|---|---|
| **Woodpecker CI** | Tira o CI da dependência da cobrança do GitHub, mas exige reescrever todos os workflows, manter um servidor de CI e expor um endpoint de webhook. Chegou a ser escrito e foi abandonado antes de instalar. Quem tem push também obteria os segredos do repositório: a troca não melhorava esse ponto |
| **Runner direto no servidor** | Um job teria acesso às credenciais de quem desenvolve na máquina |
| **Vários runners em uma VM** | Jobs simultâneos disputam portas de serviço (`3306:3306`) e o PHP global do `setup-php` |
| **VM reaproveitada, com limpeza entre jobs** | Testada e descartada: arquivo gravado com root sobrevivia, e um job malicioso poderia capturar segredos de jobs de outros repositórios |
| **Tornar este repositório privado** | Compartilhar workflow privado entre organizações exige conta Enterprise, e os consumidores estão em mais de uma |

## Consequências

- **O CI continua dependendo da cobrança do GitHub.** Um teste mostrou que, com o pagamento recusado, nem um job em
  runner próprio é criado.
- O servidor passa a concentrar desenvolvimento e builds, e a capacidade dele limita os dois.
- Cada job paga o custo de uma VM nova: cerca de 30 segundos, e sem cache local. Parte disso é compensada pela imagem-base,
  que já traz PHP e imagens de serviço.
- O serviço precisa de uma credencial no host para pedir a configuração de cada runner. Basta um token só com permissão
  de runners; o `gh` com `admin:org` é o caminho mais simples, e o mais amplo.
- A taxa por minuto de runner próprio, anunciada e adiada pelo GitHub, pode voltar. Se isso ocorrer, reavalie.
