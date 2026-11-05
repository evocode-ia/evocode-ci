#!/usr/bin/env bash
# Mantém um runner descartável: cria a VM do zero a partir da imagem-base, registra para um único job e, quando ele
# termina, joga tudo fora e recomeça.
#
#   ci-runner-ciclo NUMERO [ROTULOS]
#
# Roda como serviço (ci-runner@NUMERO). A credencial de registro fica no host e cada VM só recebe uma configuração
# de uso único. O host não confia na VM para saber que acabou: confere no GitHub e impõe um tempo máximo.
set -uo pipefail
umask 077

N="${1:?informe o número do runner}"
[[ "$N" =~ ^([1-9]|10)$ ]] || { echo "erro: número fora de 1 a 10: $N" >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/evocode-ci/runners.env
ROTULOS="${2:-$CI_LABELS}"
[[ "$ROTULOS" =~ ^[A-Za-z0-9_,-]+$ ]] || { echo "erro: rótulos inválidos" >&2; exit 1; }

VM="$(printf 'ci-runner-%02d' "$N")"
PORTA="$(printf 'civm%02d' "$N")"
FIM=$(( 9 + N ))
IP="10.77.0.$FIM"
MAC="$(printf '52:54:00:77:00:%02d' "$FIM")"
DIR=/var/lib/libvirt/images
BASE="$DIR/ci-runner-base.qcow2"
DISCO="$DIR/$VM.qcow2"
REDE="${CI_VM_NETWORK:-ci-runners}"
VCPUS="${CI_VM_VCPUS:-6}"
RAM_MB="${CI_VM_RAM_MB:-10240}"
# Acima disto a VM é destruída, com ou sem job: o limite de um job no GitHub é de 5 dias, mas aqui nenhum precisa disso.
VIDA_MAX_S="${CI_VM_VIDA_MAX_S:-28800}"
SSH=(ssh -i /etc/evocode-ci/vm_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile=/etc/evocode-ci/vm_known_hosts -o ConnectTimeout=5
  -o ServerAliveInterval=30 -o ServerAliveCountMax=6 "ci@$IP")

# Token próprio, se existir: só com permissão de runners. Sem ele, usa o gh de CI_GH_USER.
TOKEN_ARQ=/etc/evocode-ci/gh-token
gh_api() {
  if [[ -r "$TOKEN_ARQ" ]]; then
    GH_TOKEN="$(cat "$TOKEN_ARQ")" gh api "$@" 2>/dev/null
  else
    sudo -u "$CI_GH_USER" -H gh api "$@" 2>/dev/null
  fi
}

firewall_ok() {
  nft list chain inet ci_vm passagem >/dev/null 2>&1 && nft list chain bridge ci_vm_l2 entrada >/dev/null 2>&1
}

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
}

define_vm() {
  virsh dominfo "$VM" >/dev/null 2>&1 && virsh undefine "$VM" >/dev/null 2>&1
  local xml
  xml="$(mktemp)"
  # disable=svm: sem virtualização aninhada, o job tem menos superfície do KVM do host para tentar escapar.
  virt-install --print-xml --name "$VM" --osinfo ubuntu24.04 --vcpus "$VCPUS" --memory "$RAM_MB" \
    --cpu host-passthrough,disable=svm --disk "path=$DISCO,bus=virtio,discard=unmap" --import \
    --network "network=$REDE,model=virtio,mac=$MAC,target.dev=$PORTA" --graphics none \
    --console pty,target_type=serial --noautoconsole >"$xml"
  virsh define "$xml" >/dev/null
  rm -f "$xml"
}

while true; do
  remove_runner
  if ! firewall_ok; then
    echo "erro: sem as tabelas de isolamento; a VM não sobe. Rode: systemctl restart ci-runner-firewall" >&2
    virsh destroy "$VM" >/dev/null 2>&1
    sleep 30
    continue
  fi
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

  GRUPO_JSON="$(gh_api "orgs/$CI_ORG/actions/runner-groups" --jq '.runner_groups[]|select(.default)')"
  GRUPO="$(jq -r '.id // empty' <<<"$GRUPO_JSON")"
  # Em repositório público, um fork chegaria aos runners. Melhor não registrar.
  if [[ -z "$GRUPO" || "$(jq -r '.allows_public_repositories' <<<"$GRUPO_JSON")" != "false" ]]; then
    echo "erro: o grupo de runners permite repositório público ou não foi lido; não vou registrar." >&2
    virsh destroy "$VM" >/dev/null 2>&1
    sleep 60
    continue
  fi
  NOME="$VM-$(date +%s)"
  CAMPOS=(-X POST "orgs/$CI_ORG/actions/runners/generate-jitconfig" -f "name=$NOME" -F "runner_group_id=$GRUPO" -f work_folder=_work)
  # Nesta API os rótulos padrão não vêm sozinhos: sem self-hosted, nenhum job casa com o runner.
  IFS=',' read -r -a LISTA <<<"self-hosted,Linux,X64,$ROTULOS"
  for r in "${LISTA[@]}"; do CAMPOS+=(-f "labels[]=$r"); done
  RESPOSTA="$(gh_api "${CAMPOS[@]}")"
  JIT="$(jq -r '.encoded_jit_config // empty' <<<"$RESPOSTA")"
  RUNNER_ID="$(jq -r '.runner.id // empty' <<<"$RESPOSTA")"
  if [[ -z "$JIT" ]]; then
    echo "erro: o GitHub não entregou a configuração do runner. Confira a credencial." >&2
    sleep 60
    continue
  fi

  # Pela entrada padrão: o valor não aparece em processo nem em log do host. Na VM, ele já não vale depois de usado.
  printf '%s\n' "$JIT" | "${SSH[@]}" 'IFS= read -r J; export ACTIONS_RUNNER_INPUT_JITCONFIG="$J"; cd /opt/actions-runner/r1 && exec sudo --preserve-env=ACTIONS_RUNNER_INPUT_JITCONFIG -u runner ./run.sh' &
  SSH_PID=$!
  unset JIT RESPOSTA
  INICIO=$SECONDS
  VOLTA=0
  while kill -0 "$SSH_PID" 2>/dev/null; do
    if [[ "$(virsh domstate "$VM" 2>/dev/null)" != "running" ]] || ! firewall_ok; then
      break
    fi
    if (( SECONDS - INICIO > VIDA_MAX_S )); then
      echo "aviso: $VM passou do tempo máximo; destruindo." >&2
      break
    fi
    # O runner some do GitHub ao fim do job. Se a VM continuar de pé depois disso, um job a está segurando.
    VOLTA=$(( VOLTA + 1 ))
    if (( VOLTA % 6 == 0 )); then
      if ! gh_api "orgs/$CI_ORG/actions/runners/$RUNNER_ID" --jq .id >/dev/null; then
        if gh_api "orgs/$CI_ORG/actions/runner-groups" --jq '.total_count' >/dev/null; then
          echo "aviso: o runner de $VM saiu do GitHub e a VM seguia de pé; destruindo." >&2
          break
        fi
      fi
    fi
    sleep 5 &
    wait $!
  done
  kill "$SSH_PID" 2>/dev/null
  virsh destroy "$VM" >/dev/null 2>&1
  wait "$SSH_PID" 2>/dev/null
done
