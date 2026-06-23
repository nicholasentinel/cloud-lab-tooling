#!/usr/bin/env bash
#
# Interactive client for the cloud-provisioner API.
#
# A menu-driven wrapper around every caller-facing endpoint of the provisioning
# API, so you can query your accounts, provision new ones, mint console logins,
# adjust TTLs, "tear down" accounts, and (with an admin key) read/update
# budgets — without hand-writing curl. Each action prints the curl-equivalent
# it runs and the HTTP status + response body.
#
#   AWS_PROFILE=<profile> ./scripts/provision-cli.sh        # interactive menu
#   ./scripts/provision-cli.sh help                         # endpoint reference
#
# Connection & config:
#   Settings are read from ./provision.config (a KEY=value file beside this
#   script, created on first run). Precedence for each value: an exported
#   environment variable WINS and is written back to the config file; otherwise
#   the stored config value is used; otherwise you are prompted.
#
#   HOST / API_HOSTNAME   API hostname (e.g. 203-0-113-10.sslip.io). REQUIRED —
#                         set it in the environment, in provision.config, or at
#                         the prompt; the script exits if it can't be resolved.
#                         HTTPS only; the control plane serves a publicly-trusted
#                         Let's Encrypt cert, so no --cacert is needed.
#   API_KEY / X_API_KEY / MY_API_KEY   your personal X-API-Key. If unset, you
#                         are prompted (hidden) before the first authed call.
#                         Your role (requester / agent / admin) is bound to the
#                         key server-side; this script never sends a role.
#
# provision.config holds your API key — it is created chmod 600 and must stay
# gitignored. Never commit it.
#
# jq is used to pretty-print responses when available (plain text otherwise).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/provision.config"

# Capture any values exported into the environment now; HOST/API_KEY are then
# resolved (env wins, else the config file, else a prompt) in "main", once the
# config helpers below are defined.
ENV_HOST="${HOST:-${API_HOSTNAME:-}}"
ENV_KEY="${API_KEY:-${X_API_KEY:-${MY_API_KEY:-}}}"
HOST=""
API_KEY=""

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1
command -v curl >/dev/null 2>&1 || { echo "curl is required but not on PATH" >&2; exit 1; }

# --- helpers -------------------------------------------------------------

pretty() {
    # Pretty-print JSON on stdin if jq is present and the body parses; else
    # pass through unchanged (error bodies / empty responses stay readable).
    if [ "$HAVE_JQ" = 1 ]; then
        jq . 2>/dev/null || cat
    else
        cat
    fi
}

# config_get KEY  — echo the value of KEY from the config file, or empty.
# Format is KEY=value, one per line; '#'-comments and blanks are ignored. On the
# last matching line wins (so a later write supersedes an earlier one).
config_get() {
    [ -f "$CONFIG_FILE" ] || return 0
    local line
    line=$(grep -E "^$1=" "$CONFIG_FILE" 2>/dev/null | tail -n1)
    [ -n "$line" ] && printf '%s' "${line#*=}"
    return 0
}

# config_set KEY VALUE  — upsert KEY=VALUE into the config file, creating it
# (chmod 600) if absent. Never aborts the script: on any failure it warns to
# stderr and returns 0, so a read-only dir degrades to "prompt every run".
config_set() {
    local key=$1 val=$2 tmp
    if [ ! -f "$CONFIG_FILE" ]; then
        {
            printf '# provision.config — local settings for provision-cli.sh.\n'
            printf '# Holds your API key; gitignored and chmod 600. Do not commit.\n'
        } > "$CONFIG_FILE" 2>/dev/null || { echo "warning: could not create $CONFIG_FILE; values won't persist." >&2; return 0; }
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    fi
    tmp=$(mktemp 2>/dev/null) || { echo "warning: could not update $CONFIG_FILE." >&2; return 0; }
    # Drop any existing line for this key, then append the new value.
    grep -vE "^$key=" "$CONFIG_FILE" 2>/dev/null > "$tmp"
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    if mv "$tmp" "$CONFIG_FILE" 2>/dev/null; then
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    else
        rm -f "$tmp"
        echo "warning: could not update $CONFIG_FILE." >&2
    fi
    return 0
}

resolve_host() {
    # HOST has already been seeded from env or the config file by the resolution
    # block in "main". If still empty, prompt; then normalize and persist.
    if [ -z "$HOST" ]; then
        read -r -p "API hostname (e.g. 203-0-113-10.sslip.io): " HOST || true
    fi
    # Normalize: strip any scheme and trailing slash the user pasted.
    HOST="${HOST#https://}"; HOST="${HOST#http://}"; HOST="${HOST%/}"
    if [ -z "$HOST" ]; then
        echo "An API hostname is required. Set HOST (or API_HOSTNAME) in the" >&2
        echo "environment, add a HOST= line to $CONFIG_FILE, or enter it when prompted." >&2
        exit 1
    fi
    config_set HOST "$HOST"
}

ensure_key() {
    # Prompt for the API key if we don't already have one (from env, the config
    # file, or an earlier prompt), then persist it so later runs don't re-prompt.
    # Called once at startup and again before each authed action as a safety net.
    if [ -z "$API_KEY" ]; then
        read -rs -p "X-API-Key: " API_KEY; echo
        [ -n "$API_KEY" ] && config_set API_KEY "$API_KEY"
    fi
    if [ -z "$API_KEY" ]; then
        echo "An API key is required for this action. Set API_KEY (or X_API_KEY /" >&2
        echo "MY_API_KEY) in the environment, add an API_KEY= line to $CONFIG_FILE," >&2
        echo "or enter it when prompted." >&2
        return 1
    fi
}

# JSON-encode a string value. Escape backslash and double-quote (backslash
# FIRST so the quote-escapes we add aren't doubled), then the control
# characters JSON forbids bare inside a string (tab/CR/newline/etc.). Inputs
# to provision/set-ttl are charset-validated to exclude quotes, but `reason`
# is free text and `read` permits an embedded tab — escaping here keeps every
# body well-formed (a literal tab would otherwise yield 422 from the server).
jstr() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '"%s"' "$s"
}

# api METHOD PATH [BODY_FILE]
# Performs the request, echoes the curl-equivalent, prints HTTP status + body.
# Returns nonzero only on a transport failure (so menu flow continues on 4xx).
api() {
    local method=$1 path=$2 bodyfile=${3:-}
    local url="https://$HOST$path"
    local -a args=(-sS -X "$method" -H "X-API-Key: $API_KEY" -w $'\n%{http_code}')
    local shown="curl -sS -X $method 'https://$HOST$path' -H 'X-API-Key: ***'"
    if [ -n "$bodyfile" ]; then
        args+=(-H 'Content-Type: application/json' --data @"$bodyfile")
        shown+=" -H 'Content-Type: application/json' --data '$(cat "$bodyfile")'"
    fi
    echo "+ $shown" >&2
    local resp code body
    resp=$(curl "${args[@]}" "$url")
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "request failed: could not reach https://$HOST$path (curl exit $rc)" >&2
        return 1
    fi
    code=${resp##*$'\n'}
    body=${resp%$'\n'*}
    echo "HTTP $code"
    [ -n "$body" ] && printf '%s\n' "$body" | pretty
    return 0
}

# read_required PROMPT VARNAME  — re-prompt until non-empty.
read_required() {
    local prompt=$1 __var=$2 __val=""
    while [ -z "$__val" ]; do
        read -r -p "$prompt" __val || return 1
        [ -n "$__val" ] || echo "  (required)"
    done
    printf -v "$__var" '%s' "$__val"
}

valid_ttl()      { [[ $1 =~ ^[1-9][0-9]*[hdw]$ ]]; }
valid_purpose()  { [[ $1 =~ ^[A-Za-z0-9\ _.:/=+@-]+$ ]] && [ "${#1}" -le 256 ]; }
valid_acctname() { [[ $1 =~ ^[A-Za-z0-9_+=,.@\ -]+$ ]] && [ "${#1}" -ge 1 ] && [ "${#1}" -le 50 ]; }

# --- actions -------------------------------------------------------------

act_health() {
    echo "== Health (GET /health, no auth) =="
    local saved=$API_KEY; API_KEY=""        # health needs no key; don't prompt
    # Call without the X-API-Key header at all.
    local resp code
    resp=$(curl -sS -w $'\n%{http_code}' "https://$HOST/health")
    local rc=$?
    API_KEY=$saved
    [ $rc -ne 0 ] && { echo "request failed (curl exit $rc)" >&2; return; }
    code=${resp##*$'\n'}
    echo "+ curl -sS 'https://$HOST/health'" >&2
    echo "HTTP $code"
    printf '%s\n' "${resp%$'\n'*}" | pretty
}

act_list() {
    echo "== Your accounts (GET /my-accounts) =="
    ensure_key || return
    local emp=""
    read -r -p "employee_id to query (agent/admin only; blank = your own): " emp || true
    local path="/my-accounts"
    [ -n "$emp" ] && path="/my-accounts?employee_id=$emp"
    api GET "$path"
}

act_provision() {
    echo "== Provision a burner account (POST /provision) =="
    echo "Returns 202 + job_id immediately; the account is created asynchronously."
    ensure_key || return

    local provider purpose account_name ttl emp
    read -r -p "provider [aws] (aws|gcp|azure): " provider || return
    provider=${provider:-aws}
    case "$provider" in
        aws) ;;
        gcp|azure) echo "  note: only 'aws' is implemented today; '$provider' will likely fail downstream." ;;
        *) echo "  provider must be aws, gcp, or azure." >&2; return ;;
    esac

    while :; do
        read_required "purpose (ticket/project, letters digits spaces _.:/=+@- , <=256): " purpose || return
        valid_purpose "$purpose" && break
        echo "  invalid purpose (allowed: A-Z a-z 0-9 space _ . : / = + @ - ; max 256)."
    done

    while :; do
        read_required "account_name (1-50, letters digits spaces _ + = , . @ -): " account_name || return
        valid_acctname "$account_name" && break
        echo "  invalid account_name (1-50 chars; allowed: A-Z a-z 0-9 space _ + = , . @ -)."
    done

    while :; do
        read -r -p "ttl (e.g. 48h, 7d, 2w; blank = org default): " ttl || return
        [ -z "$ttl" ] && break
        valid_ttl "$ttl" && break
        echo "  invalid ttl (use N[h|d|w] with N>=1, e.g. 48h, 7d, 2w)."
    done

    emp=""
    read -r -p "employee_id (agent/admin only; blank = self / your key's identity): " emp || true

    local f; f=$(mktemp); trap 'rm -f "$f"' RETURN
    {
        printf '{'
        printf '"provider":%s' "$(jstr "$provider")"
        [ -n "$emp" ]   && printf ',"employee_id":%s' "$(jstr "$emp")"
        printf ',"purpose":%s' "$(jstr "$purpose")"
        printf ',"account_name":%s' "$(jstr "$account_name")"
        [ -n "$ttl" ]   && printf ',"ttl":%s' "$(jstr "$ttl")"
        printf '}'
    } > "$f"
    api POST "/provision" "$f"
}

act_login() {
    echo "== Console login URL (POST /my-accounts/{id}/login) =="
    echo "Returns a SHORT-LIVED signed console URL (a credential — don't share/log it)."
    ensure_key || return
    local id
    read_required "account_id: " id || return
    api POST "/my-accounts/$id/login"
}

act_set_ttl() {
    echo "== Set / clear TTL (POST /set-ttl) =="
    ensure_key || return
    local id ttl
    read_required "account_id: " id || return
    while :; do
        read -r -p "new TTL (e.g. 30d, 8h; blank = CLEAR ttl / pin open): " ttl || return
        [ -z "$ttl" ] && break
        valid_ttl "$ttl" && break
        echo "  invalid ttl (use N[h|d|w] with N>=1, or blank to clear)."
    done

    local f; f=$(mktemp); trap 'rm -f "$f"' RETURN
    if [ -z "$ttl" ]; then
        printf '{"account_id":%s,"expires_at":null}' "$(jstr "$id")" > "$f"
    else
        printf '{"account_id":%s,"expires_at":%s}' "$(jstr "$id")" "$(jstr "$ttl")" > "$f"
    fi
    api POST "/set-ttl" "$f"
}

act_teardown() {
    echo "== Tear down an account (POST /set-ttl, short TTL) =="
    echo "There is no synchronous teardown endpoint. This sets the account's TTL"
    echo "to the minimum (1h); the reaper closes it on its next sweep after it"
    echo "expires (within REAPER_SWEEP_INTERVAL_SECONDS, default 30m). To cancel,"
    echo "set a longer TTL before it expires. Watch progress via 'list accounts'"
    echo "(state goes active -> expired -> teardown_started)."
    ensure_key || return
    local id ttl confirm
    read_required "account_id to tear down: " id || return
    read -r -p "expiry TTL [1h] (minimum 1h): " ttl || return
    ttl=${ttl:-1h}
    if ! valid_ttl "$ttl"; then echo "  invalid ttl; use N[h|d|w] with N>=1." >&2; return; fi
    read -r -p "Schedule teardown of $id in $ttl? [y/N]: " confirm || return
    case "$confirm" in y|Y|yes|YES) ;; *) echo "  aborted."; return ;; esac

    local f; f=$(mktemp); trap 'rm -f "$f"' RETURN
    printf '{"account_id":%s,"expires_at":%s}' "$(jstr "$id")" "$(jstr "$ttl")" > "$f"
    api POST "/set-ttl" "$f"
}

act_get_budget() {
    echo "== Read budget (GET /admin/budget/{employee_id}) — admin key only =="
    ensure_key || return
    local emp
    read_required "employee_id: " emp || return
    api GET "/admin/budget/$emp"
}

act_update_budget() {
    echo "== Update budget (PATCH /admin/budget/{employee_id}) — admin key only =="
    ensure_key || return
    local emp limit reason
    read_required "employee_id: " emp || return
    while :; do
        read_required "new_limit_usd (number > 0, e.g. 250 or 250.00): " limit || return
        # Must be a decimal number, and strictly > 0 (i.e. contains a nonzero
        # digit — rejects 0, 0.0, 0.00).
        if [[ $limit =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ $limit =~ [1-9] ]]; then
            break
        fi
        echo "  must be a positive number (e.g. 250 or 250.00)."
    done
    reason=""
    read -r -p "reason (optional, free text): " reason || true

    local f; f=$(mktemp); trap 'rm -f "$f"' RETURN
    {
        printf '{"new_limit_usd":%s' "$limit"
        [ -n "$reason" ] && printf ',"reason":%s' "$(jstr "$reason")"
        printf '}'
    } > "$f"
    api PATCH "/admin/budget/$emp" "$f"
}

show_help() {
    cat <<EOF
cloud-provisioner API — endpoint reference

  Auth: every authed call sends your personal key in the X-API-Key header.
  The key is bound server-side to a role (requester / agent / admin):
    requester  self-service; acts only on your own accounts (identity from key)
    agent      may act on behalf of any employee_id (e.g. the Slack bot)
    admin      everything agent can do, plus /admin/*
  A missing/unknown key -> 401; a recognized key lacking the role -> 403.

  1) Health            GET  /health                 (no auth)
     Liveness only; "ok" when the process is up.

  2) List accounts     GET  /my-accounts            (any role)
     Your burner accounts + derived state (active/expired/teardown_started/
     create_failed/baseline_failed). agent/admin may add ?employee_id=… to
     view someone else's; a requester only ever sees their own.

  3) Provision         POST /provision              (any role) -> 202 + job_id
     Async create. Body: provider(aws|gcp|azure), purpose, account_name,
     optional ttl (N[h|d|w]), optional employee_id (agent/admin only).
     Only 'aws' is implemented today.

  4) Console login     POST /my-accounts/{id}/login (any role)
     Mints a short-lived signed console URL for an account you own (admin/agent:
     any account). The login_url is a ~12h CREDENTIAL — don't share/log it.

  5) Set / clear TTL   POST /set-ttl                (any role)
     Body: account_id, expires_at = N[h|d|w] to set, or null to clear (pin
     open). Requester: own accounts only; admin: any account.

  6) Tear down         POST /set-ttl (expires_at=1h)
     No synchronous teardown exists; this schedules expiry at the 1h minimum
     and the reaper closes it on its next sweep. Cancel by setting a longer TTL.

  7) Read budget       GET   /admin/budget/{employee_id}   (admin only)
     limit / spend-to-date / remaining (USD).

  8) Update budget     PATCH /admin/budget/{employee_id}   (admin only)
     Body: new_limit_usd (>0), optional reason. Applied immediately; audited.

  Full request/response schemas also render at https://$HOST/docs
EOF
}

menu() {
    # Show only whether a key is set — never the key value itself.
    local keystate; keystate=${API_KEY:+(key set)}; keystate=${keystate:-(no key yet)}
    cat <<EOF

cloud-provisioner @ https://$HOST  $keystate
  1) Health check
  2) List my accounts
  3) Provision a new account
  4) Get a console login URL
  5) Set / clear an account's TTL
  6) Tear down an account
  7) [admin] Read an employee's budget
  8) [admin] Update an employee's budget
  h) Help / endpoint reference
  q) Quit
EOF
}

# --- main ----------------------------------------------------------------

case "${1:-}" in
    -h|--help|help) HOST="${HOST:-<host>}"; show_help; exit 0 ;;
esac

# Resolve HOST / API_KEY: an exported env var WINS and is persisted to the
# config file; otherwise the stored config value is used; otherwise we prompt
# (HOST is required — resolve_host exits if it stays empty). Detection here never
# aborts the REPL.
if [ -n "$ENV_HOST" ]; then
    HOST="$ENV_HOST"
    echo "Detected API hostname in the environment — saving to $(basename "$CONFIG_FILE")."
else
    HOST="$(config_get HOST)"
fi
if [ -n "$ENV_KEY" ]; then
    API_KEY="$ENV_KEY"
    config_set API_KEY "$API_KEY"
    echo "Detected API key in the environment — saved to $(basename "$CONFIG_FILE")."
else
    API_KEY="$(config_get API_KEY)"
fi

resolve_host

# Confirm a key is present (from env or config); if not, prompt for it now —
# right after the hostname — so the REPL starts ready. Only the health check
# works without a key, so we warn but don't hard-exit if it's left blank.
if [ -z "$API_KEY" ]; then
    ensure_key || echo "Continuing without a key — only the health check will work until one is set." >&2
fi

echo "Target: https://$HOST   (TLS via Let's Encrypt — no --cacert)"

while :; do
    menu
    read -r -p "> " choice || { echo; break; }
    case "$choice" in
        1) act_health ;;
        2) act_list ;;
        3) act_provision ;;
        4) act_login ;;
        5) act_set_ttl ;;
        6) act_teardown ;;
        7) act_get_budget ;;
        8) act_update_budget ;;
        h|H|help) show_help ;;
        q|Q|quit|exit) break ;;
        "") ;;
        *) echo "unknown choice: $choice" ;;
    esac
done
