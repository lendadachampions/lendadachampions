#!/usr/bin/env bash
# Publicador na nuvem (GitHub Actions) do @lendadachampions - SEM IA e SEM o PC do usuario no caminho.
# Le fila-agendada.json (nesta pasta) e faz media_publish direto na Graph API dos itens 'pending'
# cujo horario esta a ate LEAD_SECONDS de chegar (espera ate a hora exata) ou ja passou.
#
# Idempotente: confere status_code do container antes; se ja PUBLISHED (outro publicador fez),
# so marca como publicado. Falha => exit 1 => o GitHub manda email de workflow falhou.
#
# Formato de publish_at_utc: "2026-09-19 11:30 UTC".
# Variaveis: IG_TOKEN (obrigatoria, secret), LEAD_SECONDS (padrao 600), DRY_RUN=1 (nao publica nem espera).
set -uo pipefail
cd "$(dirname "$0")"

Q=fila-agendada.json
API=https://graph.instagram.com/v21.0
IG=29150317611235973
LEAD=${LEAD_SECONDS:-600}
DRY=${DRY_RUN:-0}
: "${IG_TOKEN:?IG_TOKEN ausente}"

log() { echo "$(date -u +%FT%TZ) $*"; }
set_str() { jq --argjson i "$1" --arg k "$2" --arg v "$3" '.[$i][$k]=$v' "$Q" > "$Q.tmp" && mv "$Q.tmp" "$Q"; }
set_num() { jq --argjson i "$1" --arg k "$2" --argjson v "$3" '.[$i][$k]=$v' "$Q" > "$Q.tmp" && mv "$Q.tmp" "$Q"; }
status_of() {
  curl -s --get --data-urlencode "fields=status_code" --data-urlencode "access_token=$IG_TOKEN" "$API/$1" | jq -r '.status_code // empty'
}

FAIL=0
n=$(jq length "$Q")
for ((i = 0; i < n; i++)); do
  [ "$(jq -r ".[$i].status" "$Q")" = pending ] || continue
  label=$(jq -r ".[$i].label" "$Q")
  cid=$(jq -r ".[$i].creation_id" "$Q")
  at=$(date -u -d "$(jq -r ".[$i].publish_at_utc" "$Q")" +%s) || { log "'$label': data invalida"; FAIL=1; continue; }
  maxlate=$(jq -r ".[$i].max_atraso_min // 180" "$Q")
  diff=$((at - $(date +%s)))

  if [ "$diff" -gt "$LEAD" ] && [ "$DRY" != 1 ]; then continue; fi
  if [ "$diff" -gt 0 ]; then
    log "'$label' vence em ${diff}s"
    [ "$DRY" = 1 ] || sleep "$diff"
  fi
  late=$(( ($(date +%s) - at) / 60 ))

  if [ "$DRY" != 1 ] && [ "$late" -gt "$maxlate" ]; then
    log "'$label' PERDIDO: ${late} min de atraso (max ${maxlate}) - nao publicado"
    set_str "$i" status missed; set_str "$i" note "nao publicado: ${late} min de atraso"; FAIL=1; continue
  fi

  st=$(status_of "$cid")
  log "'$label' container $cid status=${st:-desconhecido}"
  [ "$DRY" = 1 ] && continue

  case "$st" in
    PUBLISHED) set_str "$i" status published; set_str "$i" note "ja estava publicado (outro publicador)"; continue ;;
    ERROR|EXPIRED) set_str "$i" status failed; set_str "$i" note "container $st, recriar"; log "'$label' container $st"; FAIL=1; continue ;;
    IN_PROGRESS) log "'$label' ainda IN_PROGRESS, proxima rodada"; continue ;;
  esac

  mid=""
  for try in 1 2 3; do
    resp=$(curl -s -X POST "$API/$IG/media_publish" --data-urlencode "creation_id=$cid" --data-urlencode "access_token=$IG_TOKEN")
    mid=$(echo "$resp" | jq -r '.id // empty')
    [ -n "$mid" ] && break
    log "'$label' tentativa $try falhou: $(echo "$resp" | jq -c '.error // .')"
    sleep 20
  done

  if [ -n "$mid" ]; then
    link=$(curl -s --get --data-urlencode "fields=permalink" --data-urlencode "access_token=$IG_TOKEN" "$API/$mid" | jq -r '.permalink // empty')
    set_str "$i" status published; set_str "$i" media_id "$mid"; set_str "$i" permalink "$link"
    log "PUBLICADO '$label' media_id=$mid $link"
  else
    att=$(( $(jq -r ".[$i].attempts // 0" "$Q") + 1 )); set_num "$i" attempts "$att"
    if [ "$att" -ge 6 ]; then set_str "$i" status failed; set_str "$i" note "falhou $att rodadas"; log "'$label' FALHOU de vez"; fi
    FAIL=1
  fi
done

exit "$FAIL"
