#!/usr/bin/env bash
# Cria a VM dos runners no host atual, com KVM e libvirt. Rode como root, a partir de um host Debian ou Ubuntu.
#
#   sudo CI_VM_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" infra/runner-vm/criar-vm.sh
#
# Não sobrescreve: se a VM existir, para. Passo a passo e como recriar: docs/runners.md.
set -euo pipefail
umask 022

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VM="${CI_VM_NAME:-ci-runner-01}"
VCPUS="${CI_VM_VCPUS:-6}"
RAM_MB="${CI_VM_RAM_MB:-10240}"
DISK_GB="${CI_VM_DISK_GB:-200}"
BR="${CI_VM_BRIDGE:-virbr-ci}"
REDE="${CI_VM_NETWORK:-ci-runners}"
GATEWAY="${CI_VM_GATEWAY:-10.77.0.1}"
IP="${CI_VM_IP:-10.77.0.10}"
: "${CI_VM_SSH_PUBKEY:?informe CI_VM_SSH_PUBKEY, a chave pública que administra a VM}"

# Versão fixada com o hash publicado pelo Ubuntu. Para atualizar, troque os dois juntos.
IMG_URL="${CI_VM_IMG_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
: "${CI_VM_IMG_SHA256:?informe CI_VM_IMG_SHA256, o hash de noble-server-cloudimg-amd64.img em SHA256SUMS}"

[[ "$(id -u)" -eq 0 ]] || { echo "erro: rode com sudo." >&2; exit 1; }
[[ -r /dev/kvm ]] || { echo "erro: sem /dev/kvm neste host." >&2; exit 1; }
if virsh dominfo "$VM" >/dev/null 2>&1; then
  echo "erro: a VM $VM já existe. Nada foi alterado." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  qemu-system-x86 qemu-utils seabios ipxe-qemu libvirt-daemon-system libvirt-clients \
  libvirt-daemon-driver-qemu virtinst >/dev/null
systemctl enable --now libvirtd >/dev/null

# A rede padrão do libvirt escreve as próprias regras de firewall. Aqui só existe a nossa.
if virsh net-info default >/dev/null 2>&1; then
  virsh net-destroy default >/dev/null 2>&1 || true
  virsh net-autostart default --disable >/dev/null 2>&1 || true
fi

# Regras antes da rede: a VM nunca fica sem isolamento, nem no primeiro boot.
install -m 755 "$AQUI/firewall.sh" /usr/local/sbin/ci-runner-firewall
install -m 644 "$AQUI/ci-runner-firewall.service" /etc/systemd/system/ci-runner-firewall.service
systemctl daemon-reload
systemctl reenable ci-runner-firewall.service >/dev/null 2>&1
systemctl restart ci-runner-firewall.service

if ! virsh net-info "$REDE" >/dev/null 2>&1; then
  XML="$(mktemp)"
  # mode=open: o libvirt cria a bridge e não mexe no firewall. Sem DHCP nem DNS do host: a VM usa IP fixo.
  # port isolated: as VMs não se falam, nem na camada 2, onde o firewall não enxerga.
  cat >"$XML" <<EOF
<network>
  <name>$REDE</name>
  <forward mode='open'/>
  <bridge name='$BR' stp='on' delay='0'/>
  <port isolated='yes'/>
  <dns enable='no'/>
  <ip address='$GATEWAY' netmask='255.255.255.0'/>
</network>
EOF
  virsh net-define "$XML" >/dev/null
  rm -f "$XML"
fi
virsh net-autostart "$REDE" >/dev/null
virsh net-start "$REDE" >/dev/null 2>&1 || true
systemctl restart ci-runner-firewall.service

DIR=/var/lib/libvirt/images
BASE="$DIR/ubuntu-noble-$CI_VM_IMG_SHA256.img"
if [[ ! -f "$BASE" ]]; then
  curl -fsSL -o "$BASE.tmp" "$IMG_URL"
  if [[ "$(sha256sum "$BASE.tmp" | awk '{print $1}')" != "$CI_VM_IMG_SHA256" ]]; then
    rm -f "$BASE.tmp"
    echo "erro: o hash da imagem não confere; nada foi criado." >&2
    exit 1
  fi
  mv "$BASE.tmp" "$BASE"
fi

DISCO="$DIR/$VM.qcow2"
[[ ! -e "$DISCO" ]] || { echo "erro: $DISCO já existe. Nada foi alterado." >&2; exit 1; }
qemu-img convert -O qcow2 "$BASE" "$DISCO"
qemu-img resize -q "$DISCO" "${DISK_GB}G"

SEED="$(mktemp -d)"
trap 'rm -f "$SEED"/*; rmdir "$SEED"' EXIT
sed -e "s|@NOME@|$VM|g" -e "s|@CHAVE@|$CI_VM_SSH_PUBKEY|g" "$AQUI/user-data.yaml" >"$SEED/user-data"
sed -e "s|@IP@|$IP|g" -e "s|@GATEWAY@|$GATEWAY|g" "$AQUI/network-config.yaml" >"$SEED/network-config"

virt-install --quiet --name "$VM" --osinfo ubuntu24.04 \
  --vcpus "$VCPUS" --memory "$RAM_MB" --cpu host-passthrough \
  --disk "path=$DISCO,bus=virtio,discard=unmap" --import \
  --network "network=$REDE,model=virtio" \
  --cloud-init "user-data=$SEED/user-data,network-config=$SEED/network-config" \
  --graphics none --console pty,target_type=serial \
  --noautoconsole --autostart

# No primeiro boot, o virt-install usa uma configuração em que reiniciar significa desligar. A VM termina esse boot
# desligada (user-data.yaml) e volta aqui, já com a configuração definitiva: daí em diante, reinício é reinício.
echo "Primeiro boot de $VM em andamento: instala pacotes por alguns minutos."
for _ in $(seq 1 180); do
  [[ "$(virsh domstate "$VM")" == "shut off" ]] && break
  sleep 5
done
if [[ "$(virsh domstate "$VM")" != "shut off" ]]; then
  echo "erro: o primeiro boot de $VM não terminou em 15 minutos. Confira: virsh console $VM" >&2
  exit 1
fi
virsh start "$VM" >/dev/null
echo "VM $VM criada em $IP."
