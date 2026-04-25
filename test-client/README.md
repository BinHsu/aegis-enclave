# Test client

Lightweight Alpine container that runs `smoke.sh` from inside the Docker network — the verification path mandated by [ADR-0006](../docs/ADR/0006-vpn-three-tier-story.md) and [ADR-0013](../docs/ADR/0013-deliverable-is-artifact-not-demo.md).

## Usage

```bash
make up                                 # bring up the stack

# Either path works — smoke.sh self-bootstraps `wireguard-tools` if absent.
docker compose exec test-client ./smoke.sh        # long-lived container (preferred after `up`)
docker compose run --rm test-client ./smoke.sh    # one-off container
```

Or via the Makefile:

```bash
make smoke
```

The script returns exit 0 only when steps 1-4 pass. Step 5 (host-side negative test) prints instructions because it must be run from the host shell, outside the Docker network.

## Why a separate container

Reviewers should NOT need to install WireGuard.app on their Mac, configure peer keys, and bridge to Docker Desktop. The test-client container packages the verification path so that "did this candidate's system actually work?" is a one-line check.
