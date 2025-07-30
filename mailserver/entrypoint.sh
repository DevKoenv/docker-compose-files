#!/bin/sh

set -eu

echo "Enabling Postfix SASL support..."

SASLDB_PATH="${SASLDB_PATH:-/etc/sasldb2}"
CERT_DIR="/etc/ssl/postfix/${POSTFIX_myhostname}"

ensure_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "Required command '$1' not found!"; exit 1; }
}

setup_sasl_conf() {
  echo "[setup_sasl_conf] Creating SASL config directories and files..."
  mkdir -p /etc/postfix/sasl /etc/sasl2
  cat > /etc/postfix/sasl/smtpd.conf <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN CRAM-MD5 DIGEST-MD5 NTLM
EOF
  ln -sf /etc/postfix/sasl/smtpd.conf /etc/sasl2/smtpd.conf
  echo "[setup_sasl_conf] SASL config created."
}

populate_sasl_db() {
  [ ! -f /etc/postfix/users.txt ] && { echo "[populate_sasl_db] No users.txt found, skipping SASL DB population."; return; }

  echo "[populate_sasl_db] Populating SASL DB from users.txt..."
  local mydomain bad_users first_bad_user user_count
  mydomain="$(postconf -h mydomain)"
  bad_users=""
  first_bad_user=""
  user_count=0

  # Read users.txt, ensuring the last line is processed even without a newline
  while IFS=: read -r user pass || [ -n "$user" ]; do
    # Skip empty lines and comments
    [ -z "$user" ] && continue
    case "$user" in \#*) continue ;; esac
    user="$(echo "$user" | xargs)"
    pass="$(echo "$pass" | xargs)"
    [ -z "$user" ] && continue

    if echo "$user" | grep -q "@"; then
      # User with domain
      echo "$pass" | saslpasswd2 -c -p -f "$SASLDB_PATH" "$user"
    else
      # User without domain, append default domain
      echo "$pass" | saslpasswd2 -c -p -f "$SASLDB_PATH" -u "$mydomain" "$user"
      bad_users="${bad_users:+$bad_users, }$user"
      [ -z "$first_bad_user" ] && first_bad_user="$user"
    fi
    user_count=$((user_count+1))
  done < /etc/postfix/users.txt

  if [ "$user_count" -eq 0 ]; then
    echo "[populate_sasl_db] users.txt was present but no users were found. No SASL DB created."
  else
    echo "[populate_sasl_db] SASL DB created with $user_count user(s) from users.txt"
  fi

  for db in "$SASLDB_PATH" /etc/sasl2/sasldb2; do
    [ -f "$db" ] && chown postfix:postfix "$db" && chmod 640 "$db"
  done

  if [ -n "$bad_users" ]; then
    echo "[populate_sasl_db] Some SASL users ($bad_users) were specified without the domain."
    echo "[populate_sasl_db] Container domain ($mydomain) was automatically applied."
    echo "[populate_sasl_db] To prevent this warning, specify usernames with domain: ${first_bad_user}@${mydomain}:<pass>"
    echo "[populate_sasl_db] See: https://github.com/bokysan/docker-postfix/issues/192"
  fi

  echo "[populate_sasl_db] SASL config using default $SASLDB_PATH"
}

watch_certificates() {
  echo "[watch_certificates] Checking for inotifywait command..."
  if ! command -v inotifywait >/dev/null 2>&1; then
    echo "[watch_certificates][ERROR] inotifywait not found! Certificate watching will not be enabled."
    return
  fi

  start_cert_watcher() {
    for certfile in "${CERT_DIR}/certificate.crt" "${CERT_DIR}/privatekey.key"; do
      if [ ! -f "$certfile" ]; then
        echo "[watch_certificates][WARNING] File $certfile does not exist. Certificate watcher may not work as expected."
      fi
    done

    echo "[watch_certificates] Watching certificates: ${CERT_DIR}/certificate.crt, ${CERT_DIR}/privatekey.key"
    inotifywait -m -e close_write,move,create,delete \
      "${CERT_DIR}/certificate.crt" "${CERT_DIR}/privatekey.key" 2>/dev/null |
    while read -r _ event file; do
      echo "[watch_certificates] Certificate change detected ($file, event: $event). Attempting to reload Postfix..."
      if postfix reload; then
        echo "[watch_certificates] Postfix reload succeeded."
      else
        echo "[watch_certificates][ERROR] Postfix reload failed! Please check the Postfix logs and configuration."
      fi
    done &
    if [ $? -ne 0 ]; then
      echo "[watch_certificates][ERROR] Failed to start inotifywait watcher. Certificate reload on change will not work."
    else
      echo "[watch_certificates] Watcher started for SSL certificate changes in ${POSTFIX_myhostname}."
    fi
  }

  if [ -d "$CERT_DIR" ]; then
    start_cert_watcher
  else
    echo "[watch_certificates][WARNING] Directory $CERT_DIR does not exist. Will watch for its creation in background."
    (
      inotifywait -m -e create --format '%f' /etc/ssl/postfix 2>/dev/null | while read -r newdir; do
        if [ "$newdir" = "${POSTFIX_myhostname}" ]; then
          echo "[watch_certificates] Directory $CERT_DIR created. Starting certificate watcher."
          start_cert_watcher
          break
        fi
      done
    ) &
  fi
}

main() {
  echo "[main] Ensuring required commands are available..."
  ensure_command postconf
  ensure_command saslpasswd2

  echo "[main] Configuring Postfix SASL settings..."
  postconf -e "smtpd_sasl_auth_enable=yes"
  postconf -e "broken_sasl_auth_clients=yes"

  setup_sasl_conf
  populate_sasl_db
  watch_certificates

  echo "[main] Starting main process..."
  exec /bin/sh -c "/scripts/run.sh"
}

main "$@"
