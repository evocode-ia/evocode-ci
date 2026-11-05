#!/usr/bin/env bash
# Roda DENTRO da VM, chamado por instalar-runners.sh. Lê o token de registro da entrada padrão, para ele não
# aparecer na linha de comando nem no histórico. Pode rodar de novo: não duplica o que já está registrado.
set -euo pipefail
umask 022

: "${CI_ORG:?informe CI_ORG}"
# Um por VM: jobs na mesma máquina disputam portas de serviço (3306:3306) e o PHP global do setup-php.
RUNNERS="${CI_RUNNERS:-1}"
LABELS="${CI_LABELS:-evocode-linux}"
PREFIXO="${CI_PREFIXO:-$(hostname -s)}"
BASE=/opt/actions-runner
TOOLS=/opt/hostedtoolcache

# Versão inicial, fixada com o hash publicado. Depois disso o próprio runner se atualiza, como o GitHub exige.
VERSAO=2.338.2
SHA=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40

IFS= read -r TOKEN
[[ -n "$TOKEN" ]] || { echo "erro: sem token na entrada padrão." >&2; exit 1; }

if ! id runner >/dev/null 2>&1; then
  useradd -m -s /bin/bash runner
fi
usermod -aG docker runner
# Os workflows esperam sudo sem senha, como no ubuntu-latest (setup-php, por exemplo). A VM é descartável e isolada.
echo 'runner ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/runner
chmod 440 /etc/sudoers.d/runner
install -d -o runner -g runner "$BASE" "$TOOLS"
# Dono root: um job comum não reescreve a própria limpeza. Vem de instalar-runners.sh.
install -o root -g root -m 755 /tmp/limpa-job.sh "$BASE/limpa-job.sh"
rm -f /tmp/limpa-job.sh

PACOTE=/tmp/actions-runner.tgz
TEM_PACOTE=0
pega_pacote() {
  [[ "$TEM_PACOTE" -eq 1 ]] && return 0
  curl -fsSL -o "$PACOTE" \
    "https://github.com/actions/runner/releases/download/v$VERSAO/actions-runner-linux-x64-$VERSAO.tar.gz"
  [[ "$(sha256sum "$PACOTE" | awk '{print $1}')" == "$SHA" ]] || {
    rm -f "$PACOTE"
    echo "erro: o hash do runner não confere; nada foi instalado." >&2
    exit 1
  }
  TEM_PACOTE=1
}

for n in $(seq 1 "$RUNNERS"); do
  DIR="$BASE/r$n"
  NOME="$PREFIXO-r$n"
  if [[ ! -f "$DIR/.runner" ]]; then
    pega_pacote
    install -d -o runner -g runner "$DIR"
    sudo -u runner tar -xzf "$PACOTE" -C "$DIR"
    # Pelo ambiente, não por argumento: argumento de sudo fica no log e o primeiro job conseguiria ler.
    (cd "$DIR" && ACTIONS_RUNNER_INPUT_TOKEN="$TOKEN" sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u runner \
      ./config.sh --unattended --replace --url "https://github.com/$CI_ORG" \
      --name "$NOME" --labels "$LABELS" --work _work >/dev/null)
    (cd "$DIR" && ./svc.sh install runner >/dev/null)
  fi
  # Cache de ferramentas, como /opt/hostedtoolcache no GitHub, e limpeza antes e depois de cada job.
  # O download do cache do GitHub pode travar aqui. Sem limite, o job espera 10 minutos antes de seguir sem cache.
  printf '%s\n' "AGENT_TOOLSDIRECTORY=$TOOLS" \
    "SEGMENT_DOWNLOAD_TIMEOUT_MINS=3" \
    "ACTIONS_RUNNER_HOOK_JOB_STARTED=$BASE/limpa-job.sh" \
    "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$BASE/limpa-job.sh" >"$DIR/.env"
  chown runner:runner "$DIR/.env"
  (cd "$DIR" && ./svc.sh stop >/dev/null 2>&1) || true
  (cd "$DIR" && ./svc.sh start >/dev/null)
done
rm -f "$PACOTE"

# Imagens e camadas antigas enchem o disco. O cache recente fica, para os builds seguirem rápidos.
cat >/etc/cron.daily/ci-runner-limpeza <<'EOF'
#!/bin/sh
docker system prune -af --filter until=168h >/dev/null 2>&1
docker builder prune -af --filter until=168h >/dev/null 2>&1
EOF
chmod 755 /etc/cron.daily/ci-runner-limpeza

systemctl list-units --type=service --no-legend 'actions.runner.*' | awk '{print $1, $4}'
