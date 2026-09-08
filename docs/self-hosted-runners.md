# Self-Hosted GitHub Actions Runners (homelab-tofu-workflow)

Runs on VM201 (moltbot). Two runners for this repo, isolated by label so the
multi-hour PBS drills can never starve the daily Infra Apply or the OpenClaw
contract checks again (2026-09-08 RCA: the single runner was held for hours by
the restore-from-Synology drill while scheduled Infra Apply sat queued).

| Runner                                | Labels                                    | Workloads                                    |
|---------------------------------------|-------------------------------------------|----------------------------------------------|
| `homelab-tofu-runner`                 | `self-hosted,Linux,X64,LAN,moltbot`       | Infra Apply (+tofu), OpenClaw Runtime Contract, drift-check, probes |
| `homelab-tofu-drill-runner`           | `self-hosted,Linux,X64,LAN,drill-runner`  | PBS Rebuild Drill, PBS Restore-from-Synology Drill |

Workflow `runs-on` pins:
- drills: `["self-hosted", "LAN", "drill-runner"]`
- everything else: `["self-hosted", "LAN", "moltbot"]`

The two drill workflows additionally serialize on the shared
`/tmp/pbs-drill.lock` (script-level flock, held for the entire run) — separate
runners can never run both drills concurrently because the loser dies with
"another drill is already running".

## Provisioning (reproducible, not a pet)

Both runners are user-level systemd services (linger is enabled for `moltbot`,
so they start at boot): `~/.config/systemd/user/actions-runner-homelab-tofu*.service`.

To (re)provision the drill runner from scratch:

```bash
# 1. fresh install (github.com/actions/runner, same version as the sibling)
mkdir -p ~/actions-runner-homelab-tofu-drill && cd ~/actions-runner-homelab-tofu-drill
curl -sSL -o runner.tar.gz https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz
tar xzf runner.tar.gz && rm runner.tar.gz

# 2. register (token from GH; labels MUST include the drill-runner pin)
TOKEN=$(gh api -X POST repos/karabayogo/homelab-tofu-workflow/actions/runners/registration-token | jq -r .token)
./config.sh --url https://github.com/karabayogo/homelab-tofu-workflow --token "$TOKEN" \
  --name homelab-tofu-drill-runner --labels "LAN,drill-runner" --work _work_drill --unattended

# 3. systemd unit (copy the pattern in ~/.config/systemd/user/) + enable
systemctl --user daemon-reload
systemctl --user enable --now actions-runner-homelab-tofu-drill.service

# 4. verify
gh api repos/karabayogo/homelab-tofu-workflow/actions/runners | jq -r '.runners[] | [.name,.status] | @tsv'
```

## Notes

- Do NOT copy a configured runner dir and re-register it — the `.runner*`
  migration markers make `config.sh` report "already configured". Fresh
  tarball only.
- The drills need the same host capabilities as the main runner (ssh to PVE
  with `~/.ssh/pve-kai`, Synology mount, tofu) — they run on the same VM for
  that reason.
- Runner health is part of the fiefdom daily gate (checks runner online).