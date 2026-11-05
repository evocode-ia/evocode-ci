#!/bin/bash
# Hook do runner: roda antes e depois de cada job, para um job não herdar o que o anterior deixou.
# Remove o que fica por descuido, como arquivo com segredo, checkout, container e processo. NÃO contém um job
# malicioso: ele tem root na VM e pode esconder algo fora daqui. Ver docs/runners.md.
# Nunca falha: a limpeza não pode reprovar um build.
set +e

ids="$(sudo docker ps -aq)"
[ -n "$ids" ] && sudo docker rm -f -v $ids >/dev/null 2>&1
sudo docker volume prune -af >/dev/null 2>&1
sudo docker network prune -f >/dev/null 2>&1

# Imagem construída aqui pode levar segredo em uma camada. Com o containerd, construída e baixada têm os mesmos campos,
# então o critério é a idade: o que tem menos de um dia sai. O resto fica, como cache, para não bater no limite de
# downloads do Docker Hub. Quem refaz uma imagem baixada recentemente só a baixa de novo.
limite=$(( $(date +%s) - 86400 ))
for img in $(sudo docker images -q --no-trunc | sort -u); do
  criada="$(date -d "$(sudo docker image inspect -f '{{.Created}}' "$img" 2>/dev/null)" +%s 2>/dev/null)"
  if [ -z "$criada" ] || [ "$criada" -gt "$limite" ]; then
    sudo docker rmi -f "$img" >/dev/null 2>&1
  fi
done
sudo docker builder prune -af >/dev/null 2>&1

# Processos deste usuário, menos o próprio runner e a cadeia que chamou este hook.
protegidos=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
  p="$(ps -o ppid= -p "$p" | tr -d ' ')"
  protegidos="$protegidos$p "
done
for pid in $(pgrep -u runner); do
  case "$protegidos" in *" $pid "*) continue ;; esac
  case "$(tr '\0' ' ' </proc/"$pid"/cmdline 2>/dev/null)" in
    *Runner.Listener*|*Runner.Worker*|*RunnerService*) continue ;;
  esac
  sudo kill -9 "$pid" 2>/dev/null
done

# Workspaces de todos os repositórios. Ficam só as pastas internas do runner.
WORK="${RUNNER_WORKSPACE%/*}"
if [ -n "$WORK" ] && [ -d "$WORK/_temp" ]; then
  cd / || exit 0
  find "$WORK" -mindepth 1 -maxdepth 1 ! -name '_*' -exec sudo rm -rf {} +
  # O runner espera encontrar o diretório do job atual, ainda que vazio.
  [ -n "$GITHUB_WORKSPACE" ] && mkdir -p "$GITHUB_WORKSPACE"
fi

sudo find /tmp /var/tmp -mindepth 1 -maxdepth 1 ! -name 'systemd-private-*' ! -name 'snap-private-tmp' -exec rm -rf {} + 2>/dev/null
find "$HOME" -mindepth 1 -maxdepth 1 -exec sudo rm -rf {} + 2>/dev/null

exit 0
