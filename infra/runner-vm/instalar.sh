#!/usr/bin/env bash
# Instala os runners descartáveis no host: virtualizador, firewall, rede, imagem-base e serviços.
# Rode como root, em Debian ou Ubuntu, com KVM. Pode rodar de novo: refaz a imagem-base e reinicia os serviços.
#
#   sudo CI_ORG=minha-org CI_GH_USER=meu-usuario CI_RUNNERS=3 CI_VM_IMG_SHA256=HASH infra/runner-vm/instalar.sh
#
# CI_GH_USER é o usuário do host cujo `gh` tem o escopo admin:org. Passo a passo: docs/runners.md.
set -euo pipefail
umask 022

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CI_ORG:?informe CI_ORG, a organização dona dos runners}"
: "${CI_GH_USER:?informe CI_GH_USER, o usuário do host cujo gh tem admin:org}"
: "${CI_VM_IMG_SHA256:?informe CI_VM_IMG_SHA256, o hash de noble-server-cloudimg-amd64.img em SHA256SUMS}"
RUNNERS="${CI_RUNNERS:-3}"
BR="${CI_VM_BRIDGE:-virbr-ci}"
REDE="${CI_VM_NETWORK:-ci-runners}"
IMG_URL="${CI_VM_IMG_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
BASE_NOME=ci-runner-base
DIR=/var/lib/libvirt/images
ETC=/etc/evocode-ci

# Versão inicial do runner, fixada com o hash publicado. Depois, o próprio runner se atualiza, como o GitHub exige.
RUNNER_VERSAO=2.338.2
RUNNER_SHA=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40

[[ "$(id -u)" -eq 0 ]] || { echo "erro: rode com sudo." >&2; exit 1; }
[[ -r /dev/kvm ]] || { echo "erro: sem /dev/kvm neste host." >&2; exit 1; }
# Com 0, só monta a imagem-base, sem mexer nos serviços.
[[ "$RUNNERS" -ge 0 && "$RUNNERS" -le 10 ]] || { echo "erro: CI_RUNNERS vai de 0 a 10." >&2; exit 1; }

# Cada VM pode usar 10 GB de RAM e 120 GB de disco. Sem folga no host, um job pesado derruba o desenvolvimento.
RAM_TOTAL_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1048576 ))
DISCO_LIVRE_GB=$(df --output=avail -BG /var/lib | tail -1 | tr -dc '0-9')
if (( RUNNERS * 10 + 16 > RAM_TOTAL_GB )); then
  echo "erro: $RUNNERS runners pedem $(( RUNNERS * 10 )) GB de RAM, e o host tem $RAM_TOTAL_GB GB." >&2
  exit 1
fi
if (( RUNNERS * 120 + 50 > DISCO_LIVRE_GB )); then
  echo "erro: $RUNNERS runners podem usar $(( RUNNERS * 120 )) GB de disco, e há $DISCO_LIVRE_GB GB livres." >&2
  exit 1
fi

# A imagem-base nasce na mesma rede dos runners: nenhum job roda enquanto isso.
for unidade in $(systemctl list-units --plain --no-legend 'ci-runner@*' 2>/dev/null | awk '{print $1}'); do
  systemctl stop "$unidade"
done

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  qemu-system-x86 qemu-utils seabios ipxe-qemu libvirt-daemon-system libvirt-clients \
  libvirt-daemon-driver-qemu virtinst openssh-client >/dev/null
systemctl enable --now libvirtd >/dev/null

# A rede padrão do libvirt escreve as próprias regras de firewall. Aqui só existe a nossa.
if virsh net-info default >/dev/null 2>&1; then
  virsh net-destroy default >/dev/null 2>&1 || true
  virsh net-autostart default --disable >/dev/null 2>&1 || true
fi

# Regras antes da rede: a VM nunca fica sem isolamento, nem no primeiro boot.
install -m 755 "$AQUI/firewall.sh" /usr/local/sbin/ci-runner-firewall
install -m 755 "$AQUI/ciclo-runner.sh" /usr/local/sbin/ci-runner-ciclo
install -m 644 "$AQUI/ci-runner-firewall.service" /etc/systemd/system/ci-runner-firewall.service
install -m 644 "$AQUI/ci-runner@.service" /etc/systemd/system/ci-runner@.service
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
  <ip address='10.77.0.1' netmask='255.255.255.0'/>
</network>
EOF
  virsh net-define "$XML" >/dev/null
  rm -f "$XML"
fi
virsh net-autostart "$REDE" >/dev/null
virsh net-start "$REDE" >/dev/null 2>&1 || true
systemctl restart ci-runner-firewall.service

# Chaves só destas VMs. A de administração não é pessoal, e a do host da VM é conferida a cada conexão.
install -d -m 700 "$ETC"
[[ -f "$ETC/vm_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C ci-runner-admin -f "$ETC/vm_ed25519"
SEED="$(mktemp -d)"
trap 'rm -rf "$SEED"' EXIT
ssh-keygen -q -t ed25519 -N '' -C ci-runner-host -f "$SEED/host"
echo "10.77.0.* $(cut -d' ' -f1,2 "$SEED/host.pub")" >"$ETC/vm_known_hosts"
chmod 600 "$ETC/vm_known_hosts"

CHAVE_ADMIN="$(cat "$ETC/vm_ed25519.pub")"
CHAVE_HOST_PUB="$(cat "$SEED/host.pub")"
export CHAVE_ADMIN CHAVE_HOST_PUB RUNNER_VERSAO RUNNER_SHA
python3 -I "$AQUI/gera-seed.py" "$AQUI/user-data.yaml" "$SEED/host" "$SEED/user-data" "$SEED/network-config"

IMG="$DIR/ubuntu-noble-$CI_VM_IMG_SHA256.img"
if [[ ! -f "$IMG" ]]; then
  curl -fsSL -o "$IMG.tmp" "$IMG_URL"
  if [[ "$(sha256sum "$IMG.tmp" | awk '{print $1}')" != "$CI_VM_IMG_SHA256" ]]; then
    rm -f "$IMG.tmp"
    echo "erro: o hash da imagem não confere; nada foi criado." >&2
    exit 1
  fi
  mv "$IMG.tmp" "$IMG"
fi

# A imagem-base nasce em uma VM temporária, que instala tudo e se desliga. Depois fica só o disco, somente leitura.
virsh destroy "$BASE_NOME" >/dev/null 2>&1 || true
virsh undefine "$BASE_NOME" --remove-all-storage >/dev/null 2>&1 || true
NOVA="$DIR/$BASE_NOME-nova.qcow2"
rm -f "$NOVA"
qemu-img convert -O qcow2 "$IMG" "$NOVA"
qemu-img resize -q "$NOVA" 120G
virt-install --quiet --name "$BASE_NOME" --osinfo ubuntu24.04 \
  --vcpus 6 --memory 8192 --cpu host-passthrough \
  --disk "path=$NOVA,bus=virtio" --import \
  --network "network=$REDE,model=virtio,mac=52:54:00:77:00:09,target.dev=civm00" \
  --cloud-init "user-data=$SEED/user-data,network-config=$SEED/network-config" \
  --graphics none --console pty,target_type=serial --noautoconsole
echo "Montando a imagem-base: leva alguns minutos."
for _ in $(seq 1 360); do
  [[ "$(virsh domstate "$BASE_NOME" 2>/dev/null)" != "running" ]] && break
  sleep 5
done
if [[ "$(virsh domstate "$BASE_NOME" 2>/dev/null)" == "running" ]]; then
  echo "erro: a imagem-base não terminou em 30 minutos. Confira: virsh console $BASE_NOME" >&2
  exit 1
fi
virsh undefine "$BASE_NOME" >/dev/null 2>&1 || true
chmod 444 "$NOVA"
mv -f "$NOVA" "$DIR/$BASE_NOME.qcow2"

printf 'CI_ORG=%s\nCI_GH_USER=%s\nCI_LABELS=%s\n' "$CI_ORG" "$CI_GH_USER" "${CI_LABELS:-evocode-linux}" >"$ETC/runners.env"
chmod 600 "$ETC/runners.env"

if [[ "$RUNNERS" -gt 0 ]]; then
  for n in $(seq 1 "$RUNNERS"); do
    systemctl enable "ci-runner@$n.service" >/dev/null 2>&1
    systemctl restart "ci-runner@$n.service"
  done
fi
echo "Pronto: $RUNNERS runners. Confira em Settings > Actions > Runners."
