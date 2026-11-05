#!/usr/bin/env bash
# Isola a rede das VMs dos runners. Quem dá push executa código como root na VM, então ela só pode sair para a internet:
# nada do host, da rede local, de redes privadas, da tailnet nem de outra VM.
#
# Duas tabelas nft próprias:
#   ci_vm      bloqueios de IP, com prioridade anterior à do iptables. No nft, drop é final: continuam valendo quando o
#              Docker ou o Tailscale reordenam as próprias regras ao reiniciar.
#   ci_vm_l2   amarra cada porta ao MAC e ao IP da própria VM. Sem isto, um job com root assume o IP de outra VM e recebe
#              do host a configuração de registro que era dela.
# O iptables só cuida do que precisa dele: liberar a passagem, já que a política de FORWARD do host é DROP, e o NAT.
#
#   ci-runner-firewall         aplica. Pode rodar de novo: refaz do zero.
#   ci-runner-firewall parar   remove tudo.
set -euo pipefail

BR="${CI_VM_BRIDGE:-virbr-ci}"
NET="${CI_VM_NET:-10.77.0.0/24}"
GW="${CI_VM_GATEWAY:-10.77.0.1}"

parar() {
  nft delete table inet ci_vm 2>/dev/null || true
  nft delete table bridge ci_vm_l2 2>/dev/null || true
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

# Regras de cada porta: posição 0 é a VM que monta a imagem-base; 1 a 10 são os runners.
regras_l2() {
  local fim porta mac ip
  for fim in 9 10 11 12 13 14 15 16 17 18 19; do
    porta="$(printf 'civm%02d' "$(( fim - 9 ))")"
    mac="$(printf '52:54:00:77:00:%02d' "$fim")"
    ip="10.77.0.$fim"
    printf '    iifname "%s" ether saddr != %s drop\n' "$porta" "$mac"
    printf '    iifname "%s" arp saddr ether != %s drop\n' "$porta" "$mac"
    printf '    iifname "%s" arp saddr ip != %s drop\n' "$porta" "$ip"
    printf '    iifname "%s" ip saddr != %s drop\n' "$porta" "$ip"
  done
}

# Só as portas das VMs conversam, e só IPv4 e ARP. Porta com outro nome não passa.
nft -f - <<EOF
table bridge ci_vm_l2
delete table bridge ci_vm_l2
table bridge ci_vm_l2 {
  chain entrada {
    type filter hook prerouting priority -200; policy accept;
    ibrname != "$BR" accept
    iifname "$BR" accept
    iifname != "civm*" drop
    ether type != { ip, arp } drop
$(regras_l2)
  }
}
EOF

# Primeiro fecha tudo: até a rota padrão aparecer, a VM não sai para lugar nenhum.
nft -f - <<EOF
table inet ci_vm
delete table inet ci_vm
table inet ci_vm {
  chain entrada {
    type filter hook input priority -10; policy accept;
    iifname "$BR" ip daddr $GW tcp sport 22 ct state established accept
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
# O teto de conexões por VM protege a tabela de conexões, que é a mesma do host: esgotada, cai até o SSH dele.
# E-mail fica bloqueado: o job sai com o IP do servidor, e spam queimaria a reputação dele.
nft -f - <<EOF
table inet ci_vm
delete table inet ci_vm
table inet ci_vm {
  set conexoes {
    type ipv4_addr
    size 65535
    flags dynamic
  }
  chain entrada {
    type filter hook input priority -10; policy accept;
    iifname "$BR" ip daddr $GW tcp sport 22 ct state established accept
    iifname "$BR" drop
  }
  chain passagem {
    type filter hook forward priority -10; policy accept;
    iifname "$BR" meta nfproto ipv6 drop
    iifname "$BR" oifname != "$WAN" drop
    oifname "$BR" iifname != "$WAN" drop
    oifname "$BR" ct state new drop
    iifname "$BR" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 240.0.0.0/4, $WAN_NET } drop
    iifname "$BR" tcp dport { 25, 465, 587 } drop
    iifname "$BR" ct state new add @conexoes { ip saddr ct count over 8192 } drop
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
