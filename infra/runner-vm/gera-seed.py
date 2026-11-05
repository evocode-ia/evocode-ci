#!/usr/bin/env python3
"""Gera o user-data e o network-config da imagem-base. Chamado por instalar.sh."""
import os
import sys

modelo, chave_host, saida_user, saida_rede = sys.argv[1:5]

with open(modelo, encoding="utf-8") as arq:
    texto = arq.read()
with open(chave_host, encoding="utf-8") as arq:
    privada = "".join("      " + linha for linha in arq)

for nome, valor in {
    "@CHAVE_ADMIN@": os.environ["CHAVE_ADMIN"],
    "@CHAVE_HOST_PUB@": os.environ["CHAVE_HOST_PUB"],
    "@CHAVE_HOST_PRIV@": privada.rstrip("\n"),
    "@RUNNER_VERSAO@": os.environ["RUNNER_VERSAO"],
    "@RUNNER_SHA@": os.environ["RUNNER_SHA"],
}.items():
    texto = texto.replace(nome, valor)
with open(saida_user, "w", encoding="utf-8") as arq:
    arq.write(texto)

# Todas as VMs nascem do mesmo disco: cada uma acha o próprio IP pelo MAC. O endereço .9 é o da VM que monta a base.
linhas = ["version: 2", "ethernets:"]
for fim in range(9, 20):
    linhas += [
        f"  slot{fim}:",
        "    match:",
        f'      macaddress: "52:54:00:77:00:{fim:02d}"',
        f"    addresses: [10.77.0.{fim}/24]",
        "    routes:",
        "      - {to: default, via: 10.77.0.1}",
        "    nameservers:",
        # DNS público: o resolvedor do host responderia nomes da tailnet.
        "      addresses: [1.1.1.1, 9.9.9.9]",
    ]
with open(saida_rede, "w", encoding="utf-8") as arq:
    arq.write("\n".join(linhas) + "\n")
