# provision-cli.sh

An interactive command-line client for the cloud-provisioner API. It's a
menu-driven wrapper around the caller-facing endpoints, so you can query your
accounts, provision new ones, mint console logins, adjust TTLs, tear accounts
down, and (with an admin key) read/update budgets — without hand-writing
`curl`. Each action prints the `curl`-equivalent it runs (with the key masked)
and the HTTP status + response body.

## Dependencies

- **bash** (the script uses bash features; it is not POSIX `sh`).
- **curl** — required. The script exits if it isn't on `PATH`.
- **jq** — optional. Used to pretty-print JSON responses; without it, bodies are
  printed as-is.

No Terraform, cloud CLI, or other tooling is needed.

## Configuration: `provision.config` vs. environment variables

The script needs two things to talk to the API:

| Setting    | Required | Purpose                                                        |
| ---------- | -------- | -------------------------------------------------------------- |
| `HOST`     | yes      | API hostname, e.g. `203-0-113-10.sslip.io` (no scheme/slash).  |
| `API_KEY`  | no\*     | Your personal `X-API-Key`. \*Required for every action except the health check; prompted if not preset. |

There are three sources for each value. **Precedence: environment variable →
config file → interactive prompt.**

### Config file (recommended)

Settings live in `provision.config`, a `KEY=value` file in the same directory as
the script. Copy the template and fill it in:

```sh
cp provision.config.example provision.config
chmod 600 provision.config      # it holds your API key
$EDITOR provision.config
```

The file is created automatically (mode `600`) on first run if it doesn't exist,
so editing the copied template is optional — you can also just let the script
prompt you and it will save your answers. `provision.config` is **gitignored**;
never commit it.

### Environment variables

Any of these are read at startup and **override** the config file:

- Host: `HOST` (or `API_HOSTNAME`)
- Key: `API_KEY` (or `X_API_KEY`, `MY_API_KEY`)

```sh
HOST=203-0-113-10.sslip.io API_KEY=your-key-here ./provision-cli.sh
```

When an environment variable is detected, the script logs that it saved the
value to `provision.config` and continues — so the next run picks it up from the
file and you don't need to re-export it.

### Resolution rules

- **`HOST` is required.** If it can't be found in the environment or the config
  file, you're prompted for it. If you still don't supply one, the script prints
  a message saying it's required and exits.
- **`API_KEY` is resolved lazily.** You're prompted (hidden input) the first time
  an authenticated action runs, and the value is saved for next time. The health
  check needs no key.

## Usage

Run interactively:

```sh
./provision-cli.sh
```

You'll see the target host and a menu:

```
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
```

Pick an option by number; the script prompts for any inputs it needs (with
validation), runs the call, and prints the result. Choose `q` to quit.

Print the endpoint reference without starting the menu:

```sh
./provision-cli.sh help
```

### Roles

Your API key is bound server-side to a role; the script never sends a role
itself:

- **requester** — self-service; acts only on your own accounts.
- **agent** — may act on behalf of any employee (e.g. an automation/bot key).
- **admin** — everything an agent can do, plus the `/admin/*` budget endpoints
  (menu items 7 and 8).

A missing/unknown key returns `401`; a recognized key lacking the required role
returns `403`.

## Notes

- The console login URL returned by option 4 is a **short-lived credential** —
  don't share or log it.
- Responses and the printed `curl`-equivalents mask the API key (`X-API-Key:
  ***`); the key value is never echoed to the terminal.
