#!/usr/bin/env bash
# Registra os runners na VM. Rode no host, com um `gh` que tenha o escopo admin:org.
#
#   CI_ORG=minha-org infra/runner-vm/instalar-runners.sh
#
# O token de registro vale uma hora e só serve para registrar. Ele passa pela entrada padrão e não fica gravado.
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CI_ORG:?informe CI_ORG, a organização dona dos runners}"
VM="${CI_VM_IP:-10.77.0.10}"
RUNNERS="${CI_RUNNERS:-1}"
LABELS="${CI_LABELS:-evocode-linux}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "ci@$VM")

TOKEN="$(gh api -X POST "orgs/$CI_ORG/actions/runners/registration-token" --jq .token)"
[[ -n "$TOKEN" ]] || { echo "erro: sem token de registro." >&2; exit 1; }

"${SSH[@]}" 'cat > /tmp/runners-na-vm.sh' <"$AQUI/runners-na-vm.sh"
"${SSH[@]}" 'cat > /tmp/limpa-job.sh' <"$AQUI/limpa-job.sh"
printf '%s\n' "$TOKEN" | "${SSH[@]}" \
  "sudo CI_ORG='$CI_ORG' CI_RUNNERS='$RUNNERS' CI_LABELS='$LABELS' bash /tmp/runners-na-vm.sh; codigo=\$?; rm -f /tmp/runners-na-vm.sh; exit \$codigo"
