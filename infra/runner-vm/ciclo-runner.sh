#!/usr/bin/env bash
# Mantém um runner descartável: cria a VM do zero a partir da imagem-base, registra para um único job e, quando ele
# termina, joga tudo fora e recomeça. Assim nada passa de um job para o outro, nem o que foi gravado com root.
#
#   ci-runner-ciclo NUMERO [ROTULOS]
#
# Roda como serviço (ci-runner@NUMERO). A credencial de registro fica no host e cada VM só recebe uma configuração
# de uso único.
set -uo pipefail

N="${1:?informe o número do runner}"
# shellcheck disable=SC1091
source /etc/evocode-ci/runners.env
ROTULOS="${2:-$CI_LABELS}"

VM="$(printf 'ci-runner-%02d' "$N")"
FIM=$(( 9 + N ))
IP="10.77.0.$FIM"
MAC="$(printf '52:54:00:77:00:%02d' "$FIM")"
DIR=/var/lib/libvirt/images
BASE="$DIR/ci-runner-base.qcow2"
DISCO="$DIR/$VM.qcow2"
REDE="${CI_VM_NETWORK:-ci-runners}"
VCPUS="${CI_VM_VCPUS:-6}"
RAM_MB="${CI_VM_RAM_MB:-10240}"
SSH=(ssh -i /etc/evocode-ci/vm_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile=/etc/evocode-ci/vm_known_hosts -o ConnectTimeout=5
  -o ServerAliveInterval=30 -o ServerAliveCountMax=6 "ci@$IP")

gh_api() { sudo -u "$CI_GH_USER" -H gh api "$@" 2>/dev/null; }

RUNNER_ID=""
remove_runner() {
  [[ -n "$RUNNER_ID" ]] && gh_api -X DELETE "orgs/$CI_ORG/actions/runners/$RUNNER_ID" >/dev/null
  RUNNER_ID=""
}
encerra() {
  virsh destroy "$VM" >/dev/null 2>&1
  remove_runner
  exit 0
}
trap encerra TERM INT

novo_disco() {
  virsh destroy "$VM" >/dev/null 2>&1
  rm -f "$DISCO"
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$DISCO"
  chown --reference="$BASE" "$DISCO"
}

define_vm() {
  virsh dominfo "$VM" >/dev/null 2>&1 && return 0
  local xml
  xml="$(mktemp)"
  virt-install --print-xml --name "$VM" --osinfo ubuntu24.04 --vcpus "$VCPUS" --memory "$RAM_MB" \
    --cpu host-passthrough --disk "path=$DISCO,bus=virtio,discard=unmap" --import \
    --network "network=$REDE,model=virtio,mac=$MAC" --graphics none --console pty,target_type=serial \
    --noautoconsole >"$xml"
  virsh define "$xml" >/dev/null
  rm -f "$xml"
}

while true; do
  remove_runner
  novo_disco
  define_vm
  if ! virsh start "$VM" >/dev/null 2>&1; then
    echo "erro: não consegui iniciar $VM" >&2
    sleep 30
    continue
  fi
  pronto=0
  for _ in $(seq 1 60); do
    if "${SSH[@]}" true 2>/dev/null; then pronto=1; break; fi
    sleep 3
  done
  if [[ "$pronto" -ne 1 ]]; then
    echo "erro: $VM não respondeu" >&2
    sleep 30
    continue
  fi

  GRUPO="$(gh_api "orgs/$CI_ORG/actions/runner-groups" --jq '.runner_groups[]|select(.default)|.id')"
  NOME="$VM-$(date +%s)"
  CAMPOS=(-X POST "orgs/$CI_ORG/actions/runners/generate-jitconfig" -f "name=$NOME" -F "runner_group_id=${GRUPO:-1}" -f work_folder=_work)
  # Nesta API os rótulos padrão não vêm sozinhos: sem self-hosted, nenhum job casa com o runner.
  IFS=',' read -r -a LISTA <<<"self-hosted,Linux,X64,$ROTULOS"
  for r in "${LISTA[@]}"; do CAMPOS+=(-f "labels[]=$r"); done
  RESPOSTA="$(gh_api "${CAMPOS[@]}")"
  JIT="$(jq -r '.encoded_jit_config // empty' <<<"$RESPOSTA")"
  RUNNER_ID="$(jq -r '.runner.id // empty' <<<"$RESPOSTA")"
  if [[ -z "$JIT" ]]; then
    echo "erro: o GitHub não entregou a configuração do runner. Confira o gh de $CI_GH_USER." >&2
    sleep 60
    continue
  fi

  # Pela entrada padrão: o valor não aparece em processo nem em log. Quando o job termina, o runner sai e o ssh volta.
  printf '%s\n' "$JIT" | "${SSH[@]}" 'IFS= read -r J; cd /opt/actions-runner/r1 && exec sudo --preserve-env=ACTIONS_RUNNER_INPUT_JITCONFIG -u runner env ACTIONS_RUNNER_INPUT_JITCONFIG="$J" ./run.sh' &
  SSH_PID=$!
  # Se a VM cair, o ssh demoraria minutos para perceber.
  while kill -0 "$SSH_PID" 2>/dev/null; do
    if [[ "$(virsh domstate "$VM" 2>/dev/null)" != "running" ]]; then
      kill "$SSH_PID" 2>/dev/null
      break
    fi
    sleep 5 &
    wait $!
  done
  wait "$SSH_PID" 2>/dev/null
  unset JIT RESPOSTA
done
