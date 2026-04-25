# WireGuard — local demo VPN gateway

This directory holds WireGuard configuration **templates** and a key-generation script. Real keys and live configs are gitignored.

## Role

Per [ADR-0006](../docs/ADR/0006-vpn-three-tier-story.md), WireGuard is **demo plumbing only**. Production architecture uses AWS Client VPN endpoint as the cloud-side VPN (see `terraform/main.tf`); NetBird is the recommended self-hosted alternative for non-AWS deployments. This directory exists so that the case-study brief's Task 2 ("Setup a VPN gateway") is satisfied with a self-contained, runnable artifact.

## Topology

Hub-and-spoke (per [ADR-0011](../docs/ADR/0011-topology-hub-and-spoke.md)): the `wg-gateway` container is the hub at `10.13.13.1`. Peers connect to the hub; peers do NOT connect to each other.

## Generate keys (run once on first setup)

```bash
mkdir -p wireguard/keys

# Server keypair
wg genkey | tee wireguard/keys/server_private.key | wg pubkey > wireguard/keys/server_public.key

# Peer 1 keypair (operator / test client)
wg genkey | tee wireguard/keys/peer1_private.key | wg pubkey > wireguard/keys/peer1_public.key

chmod 600 wireguard/keys/*.key
```

`wireguard/keys/` is gitignored — these stay on your machine.

## How configuration is generated

The `linuxserver/wireguard` Docker image **auto-generates** `wg0.conf` on first start from the environment variables in `docker-compose.yml`. Generated configs land in `./wireguard/config/`, which is mounted as `/config` inside the container.

The `wg0.conf.template` file in this directory documents the SERVER-side schema for reference, in case you want to hand-roll the config instead of relying on the auto-generation. For the demo path, the auto-generation is sufficient.

## Verification

The smoke test (`test-client/smoke.sh`) verifies WireGuard reachability from inside the Docker network. Macos-native client paths are intentionally unsupported — see [ADR-0006](../docs/ADR/0006-vpn-three-tier-story.md) for why.

## Cleanup

```bash
docker compose down -v   # tears down stack and removes db-data + wg-gateway config volumes
rm -rf wireguard/config wireguard/keys   # remove local config + keys
```
