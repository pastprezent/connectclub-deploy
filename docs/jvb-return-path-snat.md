# JVB return-path SNAT (HostPort preserve)

Durable home for the STAGE hotfix that keeps JVB ICE return traffic on the
advertised HostPort. Live on `185.219.135.194` (2026-10-19).

## Root cause

Docker `MASQUERADE` rewrites **outbound** UDP source ports from JVB containers
to ephemeral values. Clients learn a HostPort/`srflx` pair and open a NAT hole
toward that port; JVB→client connectivity checks then fail because the return
packets leave from a different sport.

Blanking / changing STUN mapped ports was the **wrong primary fix**. Mapping
Candidate Harvester / HostPort advertisement was already correct; the failure
is return-path SNAT, not the advertised candidate.

Example live rules (STAGE):

```
-A POSTROUTING -s 172.18.0.16/32 -p udp --sport 46473 -m comment --comment jvb-hostport-snat -j SNAT --to-source 185.219.135.194:46473
-A POSTROUTING -s 172.18.0.18/32 -p udp --sport 39801 -m comment --comment jvb-hostport-snat -j SNAT --to-source 185.219.135.194:39801
```

## Script

[`scripts/jvb-return-path-snat.sh`](../scripts/jvb-return-path-snat.sh)

- Discovers running `jvb-*` containers and their HostPort bindings.
- Inserts `POSTROUTING` SNAT rules tagged `jvb-hostport-snat`.
- Removes stale tagged rules when JVBs go away.
- Uses `norm_ip` so cleanup does **not** self-delete when `iptables -S` prints
  `/32` while docker inspect prints a bare IPv4 address.

## One-shot sync

```bash
cd /root/connectclub-deploy
export DOCKER_HOST_ADDRESS=185.219.135.194   # or rely on .env
sudo ./scripts/jvb-return-path-snat.sh --sync-only
```

Default (no args) syncs and prints JVBs + relevant NAT rules.

## Install + cron (every minute)

New JVBs need rules within ~1 minute. Prefer:

```bash
cd /root/connectclub-deploy
export DOCKER_HOST_ADDRESS=185.219.135.194
sudo ./scripts/jvb-return-path-snat.sh --install-cron
```

That copies the script to `/root/connectclub-deploy/jvb-return-path-snat.sh`
(stable cron path) and writes:

```cron
# /etc/cron.d/jvb-hostport-snat
* * * * * root /root/connectclub-deploy/jvb-return-path-snat.sh --sync-only >> /var/log/jvb-snat-sync.log 2>&1
```

Manual equivalent:

```bash
sudo cp scripts/jvb-return-path-snat.sh /root/connectclub-deploy/jvb-return-path-snat.sh
sudo chmod 755 /root/connectclub-deploy/jvb-return-path-snat.sh
echo '* * * * * root /root/connectclub-deploy/jvb-return-path-snat.sh --sync-only >> /var/log/jvb-snat-sync.log 2>&1' \
  | sudo tee /etc/cron.d/jvb-hostport-snat
sudo chmod 644 /etc/cron.d/jvb-hostport-snat
```

Verify:

```bash
sudo iptables -t nat -S POSTROUTING | grep jvb-hostport-snat
docker ps --filter name=jvb- --format 'table {{.Names}}\t{{.Ports}}'
```

Expect one SNAT line per JVB HostPort; rules must **remain** after sync (if they
appear then vanish, the `norm_ip` CIDR fix is missing).

## Do not touch host overrides

On STAGE/prod hosts, `docker-compose.override.yml` often carries local-only
settings such as `SCREEN_SHARING_HOST` and jvbuster static docker CLI wiring.
This SNAT work is **host iptables + cron only**. Do **not** remove or rewrite
override files, and do not drop `SCREEN_SHARING_HOST` from documented override
patterns when deploying compose changes from this repo.

## Retest checklist

1. Confirm SNAT rules present (`jvb-hostport-snat`).
2. Leave rooms → create a **new** room → join from the other device.
3. Enable mic/cam on stage; server ICE should stop timing out
   `HostPort/srflx -> client/prflx`.
