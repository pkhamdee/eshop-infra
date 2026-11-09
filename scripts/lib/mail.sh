# shellcheck shell=bash
# Sending eShop's notification emails (scripts/notify.sh, scripts/watchdog.sh). Sourced, never run:
# . "$(dirname "$0")/lib/mail.sh". Needs curl.
#
# Settings from the environment (workflows: repository variables SMTP_USERNAME and NOTIFY_EMAIL, secret SMTP_PASSWORD
# of environment smoke-test; docs/setup.md, "Smoke test email"):
#   SMTP_USERNAME   the sending account (Gmail), also the From address
#   SMTP_PASSWORD   its app password: handed to curl on stdin (--config -), never on its command line or printed
#   NOTIFY_EMAIL    the recipient; several separated by commas
#   SMTP_URL        default smtps://smtp.gmail.com:465 (TLS from the start; --ssl-reqd refuses anything less)
#
#   mail_missing                      prints the settings that are not set, space-separated; nothing when all are
#   mail_send <subject> <body file>   sends the plain-text body (UTF-8) with that subject to NOTIFY_EMAIL

mail_missing() {
  local missing=() setting
  for setting in SMTP_USERNAME SMTP_PASSWORD NOTIFY_EMAIL; do [ -n "${!setting:-}" ] || missing+=("$setting"); done
  echo "${missing[*]+${missing[*]}}"
}

mail_send() {
  local subject=$1 body=$2 message recipients=() to=() r quoted status=0
  message=$(mktemp)
  {
    echo "From: $SMTP_USERNAME"
    echo "To: $NOTIFY_EMAIL"
    echo "Subject: $subject"
    echo "Date: $(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo
    cat "$body"
  } | sed 's/$/\r/' >"$message"
  IFS=, read -ra to <<<"$NOTIFY_EMAIL"
  for r in "${to[@]}"; do r=${r// /}; [ -z "$r" ] || recipients+=(--mail-rcpt "$r"); done
  # The password goes to curl on stdin, never on its command line (which any process on the runner can read); in
  # curl's config syntax, inside quotes, with \ and " escaped.
  quoted=${SMTP_PASSWORD//\\/\\\\} quoted=${quoted//\"/\\\"}
  printf 'user = "%s:%s"\n' "$SMTP_USERNAME" "$quoted" \
    | curl --silent --show-error --fail --ssl-reqd --url "${SMTP_URL:-smtps://smtp.gmail.com:465}" \
      --mail-from "$SMTP_USERNAME" "${recipients[@]}" --config - --upload-file "$message" || status=$?
  rm -f "$message"
  return "$status"
}
