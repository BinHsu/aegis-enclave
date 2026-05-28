# ADR-0047: Local Docker stack network segmentation — `internal: true` + edge + routed-VPN traversal

## Status
Accepted (2026-05-28)

## Context

Until this ADR, the local `docker-compose` stack put **every** service —
`app`, `worker`, `dynamodb-local`, `valkey`, `elasticmq`, `wg-gateway`, and
`test-client` — on a **single flat bridge network** (`enclave-net`).
A header comment claimed the network was "internal only", but the
`internal: true` flag was not set; on Linux that comment was aspirational
(the bridge had NAT and a host-side route). On macOS the Docker Desktop
LinuxKit VM boundary kept the host out by accident, not by design.

Two architecturally significant gaps followed (surfaced during a Round-2
case-study review, GitHub issue #13):

1. **The "VPN-gated" property was theater on the positive path.** `smoke.sh`
   ran from inside `test-client`, which sat on the same flat network as `app`,
   and reached `app:8000` directly via Docker's embedded DNS (`API_BASE` =
   `http://app:8000`, line 23). The WireGuard tunnel was **never brought up**
   by the smoke test — `wireguard-tools` was installed in the image but
   unused. The only thing proving "host cannot reach the API" was (a) `app`
   not publishing a host port and (b) the macOS VM boundary. The negative
   reachability test (`make negative`: host curl to `localhost:8000` must
   fail) was real, but **the positive verification never traversed the
   gateway** — so "API reachable only through the VPN" was never actually
   exercised.

2. **No network-membership fence.** Even on macOS where the host could not
   reach in, any container on `enclave-net` could reach any other on any
   listening port. The "isolation" relied on the host boundary alone; there
   was no architectural segmentation between the data tier and a
   verification client.

The fix needed to do both: (a) split the topology so the `app` / `worker` /
data tier sit on an outbound-NAT-blocked network that no edge-side client
can route into directly, and (b) make `smoke.sh` actually demonstrate the
VPN-gated property by routing through the WireGuard gateway end-to-end.

## Decision

Adopt a **two-network segmentation + routed-VPN tunnel traversal** model
for the local stack, mirroring the production AWS Client VPN -> private ALB
shape (ADR-0027, ADR-0019). Concretely:

### 1. Two Docker networks (segmentation)

- **`edge`** — plain bridge. Carries the **only** host-published port
  (`wg-gateway: 51820/udp`) and is the only network `test-client` sees.
- **`internal`** — `driver: bridge` + **`internal: true`** + fixed CIDR
  `172.30.0.0/16`. No outbound NAT, no cross-network routing except via the
  dual-homed gateway. All of `app`, `worker`, `dynamodb-local`, `valkey`,
  `elasticmq`, `ddb-bootstrap`, `bootstrap` live here.

The fixed CIDR is required so the WireGuard peer config's `AllowedIPs` can
name the internal subnet explicitly (auto-assigned CIDRs would drift).

### 2. Dual-homed gateway

`wg-gateway` is on **both** `edge` (publishes 51820/udp; one foot
outside) and `internal` (one foot inside the data network).
`linuxserver/wireguard`'s default `PostUp` configures `ip_forward` +
`iptables MASQUERADE` on all interfaces, so traffic that enters via the
`wg0` tunnel exits via the `eth1` (internal) interface, masqueraded as the
gateway's internal IP (172.30.0.5).

### 3. Routed-VPN peer config

The gateway's `ALLOWEDIPS` env is set to **`10.13.13.0/24, 172.30.0.0/16`**
— not `0.0.0.0/0`. This pushes only two routes through the tunnel to the
peer: the WG link subnet (so the peer can reach the gateway's tunnel IP
`10.13.13.1` to query CoreDNS) and the internal Docker subnet (so the
peer's `curl http://app:8000` flows into `internal` via the gateway). The
peer's other traffic stays on `edge`. This mirrors AWS Client VPN's
"split-tunnel routes into the VPC" model rather than a full-tunnel
default route.

### 4. DNS resolution via the gateway

`linuxserver/wireguard` writes `DNS = 10.13.13.1` (the gateway's tunnel
IP) into the auto-generated peer config when `PEERDNS=auto`. The gateway
runs CoreDNS (`wireguard/config/coredns/Corefile` = `forward .
/etc/resolv.conf`), which forwards to Docker's embedded DNS (127.0.0.11)
on the gateway's internal interface. So a peer query for `app` flows:
peer -> tunnel -> gateway:53 -> CoreDNS -> Docker embedded DNS -> returns
`172.30.0.x` -> reply through tunnel -> peer curls 172.30.0.x via the
tunnel -> gateway forwards into internal.

### 5. `smoke.sh` brings up the tunnel (step 0)

A new `step 0/6` runs before the existing six application-flow steps:

```sh
PEER_CONF=/wg-config/peer1/peer1.conf
# wait up to 30s for linuxserver to generate it
sed 's|^Endpoint = .*|Endpoint = wg-gateway:51820|' "$PEER_CONF" \
    > /etc/wireguard/wg0.conf
wg-quick up wg0
trap 'wg-quick down wg0' EXIT

ping -c 1 10.13.13.1                     # gateway reachable through tunnel
APP_IP=$(getent hosts app | awk '...')   # DNS-via-gateway resolves app
case "$APP_IP" in 172.30.*) ;; *) fail ; esac   # must be the internal CIDR
```

The Endpoint rewrite (`5.28.82.226:51820` -> `wg-gateway:51820`) is required
so the UDP handshake stays inside the `edge` Docker network rather than
hairpinning through the host's external NAT. `test-client` is granted
`cap_add: [NET_ADMIN]` and mounts `./wireguard/config:/wg-config:ro`.

After step 0, the existing API_BASE (`http://app:8000`) works unchanged —
DNS resolves via the tunnel, packets route via the tunnel, source IP at
the app is the gateway's internal IP. The same `smoke.sh` file proves the
application flow **through** the gateway, end-to-end.

## Alternatives Considered

| Alternative | Why not |
|---|---|
| **Scope A — segmentation only, leave `smoke.sh` as direct-curl** | Achieves architectural segmentation but leaves the gateway as decoration that nothing traverses. The positive verification still does not actually exercise "only via VPN" — it just proves the data tier is internal-only. Rejected: the issue's acceptance criterion 2 is "API reachable only after WireGuard connect, via the gateway"; that demands a positive path through the tunnel, not a stronger version of the negative path. |
| **Option 3 — reverse-proxy on the gateway** (peer curls gateway tunnel IP; gateway nginx forwards to app:8000) | Functionally works but **diverges from the production architecture**. The cloud deployment uses AWS Client VPN (ADR-0006) -> routes into the private VPC subnet (ADR-0019) -> internal ALB (ADR-0027). That is a routed VPN, not a bastion proxy. A reverse-proxy local model would test a different topology than the one shipped to AWS. Rejected: fidelity to production beats convenience. |
| **Bind the API to one host network interface** (the instinct surfaced in #13) | Does not map to how Docker works. On macOS, the host has no L3 route to the container network at all — interface binding is meaningless. On Linux the host shares the bridge regardless of which interface the API binds to. The control surface is "is the port published" + "what network is the container on", not "which host NIC". Rejected as conflating two unrelated levers. |
| **Full-tunnel `AllowedIPs = 0.0.0.0/0`** | The linuxserver default; was the original setting. Forces all peer traffic through the tunnel, including the peer's edge-side connectivity. Rejected for the split-tunnel routed-VPN model — only the routes the peer needs to reach internal services should flow through the tunnel; the peer keeps its edge-side internet for, e.g., `apk add` during smoke bootstrap. |

## Consequences

### Positive
- **VPN-gating is now real, not theatre.** Both the negative path (host
  cannot reach the API) and the positive path (smoke traverses the tunnel
  and gets `172.30.0.x` as the source-IP at the API) are exercised by
  `make smoke && make negative`.
- **Architectural fidelity to production.** Routed-VPN + private subnet +
  internal ALB is exactly the shape the cloud Client VPN ships
  (ADR-0006/0019/0027). Local and cloud now test the same topology.
- **Network-membership fence.** `internal: true` blocks outbound NAT and
  cross-network bridging; no container on `edge` can reach `internal`
  except through the gateway. The data tier is segmented architecturally,
  not by host accident.
- **Honest negative test.** `make negative` continues to verify the host
  cannot reach the API on `localhost:8000`; the new design strengthens
  this — host cannot reach `internal` at all (no route, no NAT).

### Negative / costs
- **`test-client` needs `cap_add: [NET_ADMIN]`.** `wg-quick` creates the
  `wg0` interface and adds routes — both require `NET_ADMIN`. Documented
  in the compose comment.
- **Extra Alpine packages in `test-client`** (`openresolv`, `iptables`,
  `iproute2`). Adds ~5 MB on first install; cached on the long-lived
  container.
- **`ddb-bootstrap` profile is mandatory after every fresh `up`.** DDB
  Local is in-memory; the `executions` table dies with the container, and
  bringing the stack up does not auto-recreate it. Existing pattern,
  unchanged.
- **`smoke.sh` step 6 (backpressure) is pre-existing flaky** (tracked in
  GitHub issue #10) — the new tunnel path does not affect it. This ADR
  scopes itself to network isolation; #10 is the runtime-bug branch.
- **Two manual recreate steps when `ALLOWEDIPS` env changes.** Changing
  the env on `wg-gateway` requires `rm -rf wireguard/config/peer1` +
  `docker compose up -d --force-recreate wg-gateway` so the image
  regenerates `peer1.conf` with the new routes. Documented in
  `wireguard/README.md`.

### Platform caveats (per the #13 review comment)
The fix is **macOS-shaped** — this repo's actual local-stack verification
platform (CLAUDE.md §7). On Linux or in Kubernetes the same logical model
holds, but the enforcement layer differs:

- **Linux Docker.** `docker0` / `br-*` bridges live on the host with a
  host-side route, so an unpublished container port is still reachable
  from the host via the container IP (`-p` only adds DNAT, not the only
  path). Linux forkers need one of: shared netns
  (`network_mode: "container:<gateway>"`), `macvlan` / `ipvlan` (host
  cannot reach its own macvlan containers by default), or host iptables
  `DROP host -> internal subnet except gateway`. `internal: true` helps
  but must be verified with `curl` from host + `iptables -L` rather than
  assumed.
- **Kubernetes.** A `Service` is discovery + load-balancing, not a
  firewall. Pods are reachable by Pod IP directly, bypassing the Service.
  The real pod-to-pod boundary is a `NetworkPolicy` (default is allow-all
  until one exists), and only certain CNIs enforce it — on local clusters
  with `kindnet` / `flannel` it is a silent no-op; needs Calico / Cilium.
  The k8s VPN-gating shape is: API as ClusterIP (or headless) +
  default-deny `NetworkPolicy` allowing only the gateway pod + gateway as
  the only externally exposed thing.

The unifying lesson: in both Docker and k8s, the layer used to **describe**
a service (`Service` / `ports:`) is not the layer that **enforces**
isolation (`NetworkPolicy` + CNI / Docker network topology + firewall).
Verification must be from the attacker's side — reach it the wrong way
and confirm it fails — not from reading the abstraction's name.

## Related ADRs

- **ADR-0006** — three-tier VPN story (WireGuard local / Client VPN cloud
  / NetBird production). This ADR is the local tier's segmentation.
- **ADR-0011** — hub-and-spoke topology. The dual-homed gateway is the hub.
- **ADR-0013** — deliverable-not-demo. The smoke test is the deliverable;
  this ADR makes its VPN claim non-theater.
- **ADR-0014** — Mermaid smoke-test acceptance. Acceptance criteria for #13
  fold into this ADR's "Decision § 5".
- **ADR-0019** — private-only VPC (no IGW, no NAT). The cloud analog of
  `internal: true`.
- **ADR-0027** — internal ALB. The cloud analog of `app` on internal-only.
