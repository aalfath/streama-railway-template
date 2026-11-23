#!/bin/sh
# Start Streama on Railway.
# - Keeps all state under $STREAMA_DATA_DIR (/data, a Railway volume): H2 database, remember-me key, uploads.
# - Sizes the JVM to the container's memory limit, so it runs on a 0.5 GB service.
# - First boot only: upstream creates the user admin/admin. We start Streama on localhost only,
#   change that password to $ADMIN_PASSWORD, set the upload directory and base URL, stop it,
#   and only then start it on the public port. The default password is never reachable from outside.
# - Exits non-zero when Streama dies (including on OutOfMemoryError), so Railway restarts it.
set -eu

DATA="${STREAMA_DATA_DIR:-/data}"
PORT="${PORT:-8080}"
JAR=/app/streama.jar
MARKER="$DATA/.streama-admin-initialized"
mkdir -p "$DATA" "$DATA/media"
cd "$DATA"

log() { echo "[start] $*"; }

# ---- JVM sizing from the cgroup memory limit ----
limit=""
if [ -r /sys/fs/cgroup/memory.max ]; then limit=$(cat /sys/fs/cgroup/memory.max)
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes); fi
case "$limit" in ''|max) limit=0 ;; esac
mb=$((limit / 1048576))
if [ "$mb" -gt 0 ] && [ "$mb" -le 800 ]; then
  # Small plan (e.g. Railway Free/Trial 0.5 GB): tight heap, C1 only, few threads.
  JVM_MEM="-Xmx200m -Xms64m -Xss256k -XX:MaxMetaspaceSize=128m -XX:CompressedClassSpaceSize=32m -XX:ReservedCodeCacheSize=40m -XX:MaxDirectMemorySize=32m -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -XX:CICompilerCount=1"
  TOMCAT_THREADS=20
else
  # Larger plan: half the limit for the heap, between 256 MB and 1536 MB (Streama needs little heap;
  # the rest is left for metaspace, threads and the OS file cache for streaming). No limit: 512 MB.
  if [ "$mb" -gt 0 ]; then heap=$((mb / 2)); else heap=512; fi
  [ "$heap" -gt 1536 ] && heap=1536
  [ "$heap" -lt 256 ] && heap=256
  JVM_MEM="-Xmx${heap}m -Xms64m -XX:MaxMetaspaceSize=256m -XX:+UseSerialGC"
  TOMCAT_THREADS=100
fi
log "memory limit ${mb} MB; JVM: ${JVM_MEM}"

APP_PROPS="-Dgrails.env=docker -Dstreama.rememberMeKeyFile=$DATA/streama-remember-me.key -Dserver.tomcat.max-threads=$TOMCAT_THREADS -Dfile.encoding=UTF-8 -Djava.security.egd=file:/dev/./urandom"
# shellcheck disable=SC2086
run_java() { exec java $JVM_MEM -XX:+ExitOnOutOfMemoryError $APP_PROPS ${JAVA_OPTS:-} "$@" -jar "$JAR"; }
# Stop the first-boot JVM and wait until it has exited, so it releases the H2 database file.
stop_java() {
  kill "$pid" 2>/dev/null || true
  n=0; while kill -0 "$pid" 2>/dev/null && [ $n -lt 60 ]; do sleep 1; n=$((n+1)); done
  if kill -0 "$pid" 2>/dev/null; then log "first-boot JVM did not stop in 60 s; killing it"; kill -9 "$pid" 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null || true
  log "first-boot JVM stopped after ${n} s"
}

# ---- First boot: secure the admin account before the public port opens ----
# Railway can start two deployments at once on a new service; only one may run the first boot.
exec 9>"$DATA/.first-boot.lock"
flock -w 900 9 || { log "could not get the first-boot lock"; exit 1; }
if [ ! -f "$MARKER" ]; then
  if [ -z "${ADMIN_PASSWORD:-}" ] || [ "${#ADMIN_PASSWORD}" -lt 6 ]; then
    log "ADMIN_PASSWORD must be set (at least 6 characters) for the first start"; exit 1
  fi
  IPORT=18080
  log "first boot: starting Streama on 127.0.0.1:$IPORT to set the admin password"
  # Subshell + exec: $pid is the JVM itself, not a wrapper shell.
  ( run_java -Dserver.address=127.0.0.1 -Dserver.port=$IPORT ) &
  pid=$!
  ok=""
  i=0
  while [ $i -lt 600 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then log "Streama exited during first boot"; exit 1; fi
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$IPORT/login/auth")" = 200 ]; then ok=1; break; fi
    sleep 1; i=$((i+1))
  done
  [ -n "$ok" ] || { log "Streama did not answer within 600 s"; stop_java; exit 1; }

  B="http://127.0.0.1:$IPORT"
  CJ=$(mktemp)
  login() { # $1 = password; succeeds when the login redirects to the app, not to authfail
    rm -f "$CJ"
    loc=$(curl -s -c "$CJ" -o /dev/null -w '%{redirect_url}' --data-urlencode "username=admin" --data-urlencode "password=$1" "$B/login/authenticate")
    case "$loc" in *authfail*|'') return 1 ;; *) return 0 ;; esac
  }
  if login admin; then
    body=$(jq -n --arg p "$ADMIN_PASSWORD" '{oldPassword:"admin",newPassword:$p,repeatPassword:$p}')
    code=$(curl -s -b "$CJ" -c "$CJ" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$body" "$B/user/changePassword.json")
    [ "$code" = 202 ] || { log "changing the admin password failed (HTTP $code)"; stop_java; exit 1; }
    login "$ADMIN_PASSWORD" || { log "login with the new admin password failed"; stop_java; exit 1; }
    log "admin password set from ADMIN_PASSWORD"
  elif login "$ADMIN_PASSWORD"; then
    log "admin password was already set"
  else
    log "admin login failed with both the default and ADMIN_PASSWORD; leaving the account as it is"
    stop_java; exit 1
  fi

  # Preset the settings Streama asks for on first login: upload directory on the volume, and the base URL.
  BASE_URL=""
  [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ] && BASE_URL="https://$RAILWAY_PUBLIC_DOMAIN"
  settings=$(curl -s -b "$CJ" "$B/settings/index.json")
  upd=$(printf '%s' "$settings" | jq -c --arg up "$DATA/media" --arg base "$BASE_URL" '
    [ .[] | select(.settingsKey=="Upload Directory" and ((.value // "")=="")) | {id, value:$up} ]
    + (if $base=="" then [] else [ .[] | select(.settingsKey=="Base URL" and ((.value // "")=="" or .value=="http://localhost:8080")) | {id, value:$base} ] end)')
  if [ "$upd" != "[]" ] && [ -n "$upd" ]; then
    code=$(curl -s -b "$CJ" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$upd" "$B/settings/updateMultiple.json")
    log "preset settings (upload directory, base URL): HTTP $code"
  fi
  # H2 writes to disk with a short delay: read the settings back, then give it time to flush
  # before stopping the JVM, so the presets are not lost.
  up_now=$(curl -s -b "$CJ" "$B/settings/index.json" | jq -r '.[] | select(.settingsKey=="Upload Directory") | .value // ""')
  [ "$up_now" = "$DATA/media" ] || { log "upload directory setting did not stick (got '$up_now')"; stop_java; exit 1; }
  rm -f "$CJ"
  sleep 5

  touch "$MARKER"
  stop_java
  log "first boot done; starting on the public port"
fi
exec 9>&-

log "starting Streama on 0.0.0.0:$PORT"
# exec so Streama's exit code is the container's: a crash or OOM exits non-zero and Railway restarts it.
# shellcheck disable=SC2086
exec java $JVM_MEM -XX:+ExitOnOutOfMemoryError $APP_PROPS ${JAVA_OPTS:-} -Dserver.port="$PORT" -jar "$JAR"
