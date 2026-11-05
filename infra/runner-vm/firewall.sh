#!/usr/bin/env bash
# Isola a rede das VMs dos runners. Quem dá push executa código na VM, então ela só pode sair para a internet:
# nada do host, da rede local, de redes privadas, da tailnet nem de outra VM.
#
# Os bloqueios ficam em tabela nft própria, com prioridade anterior à do iptables. No nft, drop é final: por isso eles
# continuam valendo quando o Docker ou o Tailscale reordenam as próprias regras ao reiniciar. O iptables só cuida do
# que precisa dele: liberar a passagem, já que a política de FORWARD do host é DROP, e o NAT.
#
#   ci-runner-firewall         aplica. Pode rodar de novo: refaz do zero.
#   ci-runner-firewall parar   remove tudo.
set -euo pipefail

BR="${CI_VM_BRIDGE:-virbr-ci}"
NET="${CI_VM_NET:-10.77.0.0/24}"

parar() {
  nft delete table inet ci_vm 2>/dev/null || true
  iptables -D FORWARD -j CI-VM-FWD 2>/dev/null || true
  iptables -F CI-VM-FWD 2>/dev/null || true
  iptables -X CI-VM-FWD 2>/dev/null || true
  iptables -t nat -D POSTROUTING -j CI-VM-NAT 2>/dev/null || true
  iptables -t nat -F CI-VM-NAT 2>/dev/null || true
  iptables -t nat -X CI-VM-NAT 2>/dev/null || true
}

if [[ "${1:-}" == "parar" ]]; then
  parar
  exit 0
fi

# Primeiro fecha tudo: até a rota padrão aparecer, a VM não sai para lugar nenhum.
nft -f - <<EOF
table inet ci_vm
delete table inet ci_vm
table inet ci_vm {
  chain entrada {
    type filter hook input priority -10; policy accept;
    iifname "$BR" ct state established,related accept
    iifname "$BR" drop
  }
  chain passagem {
    type filter hook forward priority -10; policy accept;
    iifname "$BR" drop
    oifname "$BR" drop
  }
}
EOF

WAN=""
for _ in $(seq 1 30); do
  WAN="$(ip -4 route show default | awk 'NR==1{print $5}')"
  [[ -n "$WAN" ]] && break
  sleep 2
done
if [[ -z "$WAN" ]]; then
  echo "aviso: sem rota padrão; as VMs ficam sem rede até este serviço rodar de novo." >&2
  exit 0
fi

WAN_NET="$(ip -4 route show dev "$WAN" scope link | awk 'NR==1{print $1}')"
if [[ -z "$WAN_NET" ]]; then
  echo "erro: não achei a sub-rede de $WAN; as VMs ficam sem rede." >&2
  exit 1
fi

# A sub-rede pública do host pode ter máquinas vizinhas. O gateway segue funcionando: é o próximo salto, não o destino.
nft -f - <<EOF
table inet ci_vm
delete table inet ci_vm
table inet ci_vm {
  chain entrada {
    type filter hook input priority -10; policy accept;
    iifname "$BR" ct state established,related accept
    iifname "$BR" drop
  }
  chain passagem {
    type filter hook forward priority -10; policy accept;
    iifname "$BR" meta nfproto ipv6 drop
    iifname "$BR" oifname != "$WAN" drop
    oifname "$BR" iifname != "$WAN" drop
    oifname "$BR" ct state new drop
    iifname "$BR" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, $WAN_NET } drop
  }
}
EOF

sysctl -q -w net.ipv4.ip_forward=1

iptables -N CI-VM-FWD 2>/dev/null || iptables -F CI-VM-FWD
iptables -A CI-VM-FWD -i "$BR" -o "$WAN" -s "$NET" -j ACCEPT
iptables -A CI-VM-FWD -i "$WAN" -o "$BR" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C FORWARD -j CI-VM-FWD 2>/dev/null || iptables -I FORWARD 1 -j CI-VM-FWD

iptables -t nat -N CI-VM-NAT 2>/dev/null || iptables -t nat -F CI-VM-NAT
iptables -t nat -A CI-VM-NAT -s "$NET" -o "$WAN" -j MASQUERADE
iptables -t nat -C POSTROUTING -j CI-VM-NAT 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j CI-VM-NAT

# Da versão anterior deste script, que bloqueava pelo iptables.
iptables -D INPUT -j CI-VM-IN 2>/dev/null || true
iptables -F CI-VM-IN 2>/dev/null || true
iptables -X CI-VM-IN 2>/dev/null || true
