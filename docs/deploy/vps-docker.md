---
title: Docker VPS deployment
summary: Deploy Paperclip on a customer-owned Linux VPS with HTTPS, persistent storage, and repeatable upgrades
---

# Docker VPS deployment

Use this profile for a single Paperclip instance on a customer-owned Linux VPS.
It builds Paperclip from the Git checkout you deploy, then runs Paperclip,
PostgreSQL, and Caddy in Docker Compose. Caddy obtains and renews HTTPS
certificates automatically. PostgreSQL and Paperclip are not published directly
to the internet; only Caddy listens on ports 80 and 443.

## Requirements

- A Linux VPS with a public IPv4 address (and a valid IPv6 route if an AAAA
  record is configured).
- Docker Engine and the Docker Compose v2 plugin.
- A DNS A/AAAA record for the chosen hostname pointing to the VPS.
- Inbound TCP ports 80 and 443 allowed by both the cloud firewall and host
  firewall. UDP 443 is optional and enables HTTP/3.
- At least 2 CPU cores and 4 GB RAM; 8 GB or more is recommended because the
  Paperclip source image is built on the VPS. Also provide enough disk for the
  database, agent workspaces, uploaded files, and backups.

## Install

Clone your fork on the VPS (or transfer your private fork's source checkout with
a read-only deploy key), then run the deployment helper from that checkout:

```sh
git clone https://github.com/YOUR_GITHUB_USER/paperclip.git
cd paperclip
git checkout YOUR_DEPLOYMENT_REF
cd deploy/vps
chmod +x install.sh upgrade.sh backup.sh
./install.sh
```

The installer requires a clean Git checkout, asks for the public hostname,
builds the Paperclip image from the checked-out fork commit, records that full
commit SHA, generates unique database and authentication secrets, and starts the
stack. It does not pull a Paperclip image from the upstream project's registry.

The installer never overwrites an existing `.env`. Store `deploy/vps/.env`
securely: it contains the deployment's credentials. It is created with mode
`0600` and excluded from Git. The container's Paperclip user is built with the
VPS operator's UID/GID so it can write the persistent bind-mounted data.

Once DNS points to the VPS and the firewall is open, visit the printed HTTPS
URL. For a fresh `authenticated/public` deployment, create the first-admin
invite from the Paperclip container and open the printed URL:

```sh
docker compose -f compose.yaml exec -T paperclip pnpm paperclipai auth bootstrap-ceo
```

Treat the invite URL as a secret and send it to the customer through a secure
channel. The invite is one-time and expires. Complete first-admin setup before
sharing the public URL with other users.

## Configure agents and model access

Paperclip can be used before an agent provider is configured. After signing in,
add the customer's provider connection and select it for the agents. Avoid
putting provider keys in the Compose file or `.env`; enter credentials through
Paperclip's connection/secret UI so they are stored using the instance's secret
provider.

## Operate the deployment

Run these commands from `deploy/vps/`:

```sh
docker compose -f compose.yaml ps
docker compose -f compose.yaml logs -f paperclip
docker compose -f compose.yaml logs -f caddy
./backup.sh
```

Backups briefly stop Paperclip so the PostgreSQL dump and local instance files
form one consistent recovery point. The resulting files are under
`deploy/vps/backups/`; protect and copy them off the VPS. Each backup contains
`database.dump`, `instance-data.tar.gz`, and `deployment.env`. All three contain
sensitive data: the instance archive has the encrypted-secrets master key, and
the environment file has authentication and database secrets.

## Upgrade

Make a backup before each upgrade. Pass a commit SHA or a fetched Git ref from
your fork, such as `origin/customer-release`. The helper backs up the instance,
fetches Git refs, checks out that exact commit, builds Paperclip from your
source, records the deployed SHA in `.env`, and updates the service:

```sh
./upgrade.sh origin/customer-release
```

Use the exact reviewed commit intended for the client. The helper restores the
previous source checkout if the image build fails. If the updated service does
not become healthy, it leaves the new source selected and prints recent logs;
review the failure and restore from the backup before attempting a downgrade
across a database migration.

## Troubleshooting

- **Caddy cannot issue a certificate:** confirm public DNS resolves to this
  VPS and TCP ports 80/443 are reachable. Check `docker compose -f compose.yaml
  logs caddy`.
- **Paperclip does not become healthy:** check `docker compose -f compose.yaml
  logs paperclip db`; confirm the VPS has enough memory and disk.
- **The URL or auth redirects to the wrong host:** verify `PAPERCLIP_DOMAIN` in
  `.env`, then run `docker compose -f compose.yaml up -d` to apply it.
- **The disk is filling:** inspect Docker logs, PostgreSQL volume usage, the
  `data/` directory, and retained backups. Set a backup retention policy before
  enabling unattended backups.
- **The checkout is private:** configure a read-only Git deploy key for the
  customer's VPS. Do not put the key in the repository, Compose file, or `.env`.

The bundle does not configure the VPS operating system firewall, DNS, a cloud
provider account, provider billing, or agent-specific integrations. Complete
those explicitly with the customer and verify them before handoff.
