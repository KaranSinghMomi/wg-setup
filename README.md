# WireGuard one-command installer, with Telegram config delivery

A single shell script that turns a fresh Ubuntu server into a WireGuard VPN and
sends you the client config — as a `.conf` file **and** a QR code — over Telegram.

- **One command.** No Docker, no image registry, no build step.
- **Any architecture.** ARM (Oracle Ampere A1) and x86 alike.
- **Several UDP ports at once** — or **any port at all** with `--any-port`, so a
  network that blocks one port is worked around by editing a single number in the
  client config.
- **Multiple servers, one chat.** Every server posts its own config into the same
  Telegram chat, identified by its public IP.

---

## Quick start

### 1. Create the Telegram bot (once, ever)

1. Message **@BotFather**, send `/newbot`, and note the token.
2. Create a group (or just use your own DM) and add the bot to it.
3. Send any message in that chat, then read the chat id:

   ```bash
   curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" \
     | jq '.result[-1].message.chat.id'
   ```

   Group ids are negative, e.g. `-1001234567890`.

### 2. Open the ports in your cloud firewall

This is the one step the script **cannot** do for you — it runs inside the VM,
and the cloud firewall is enforced outside it.

On **Oracle Cloud**: Networking → Virtual Cloud Networks → your VCN → Security
Lists → Default Security List → **Add Ingress Rules**, source `0.0.0.0/0`,
IP Protocol **UDP**, then:

| If you install with | Destination port range |
|---|---|
| `--any-port` | **leave empty** (means all ports) |
| a fixed `--ports` list | `53,9200,9201` — matching your list exactly |

Whichever you choose, the cloud firewall is the outer gate: ports it blocks never
reach the server, no matter what the server itself allows.

> Note for people coming from Contabo: Contabo has no cloud firewall, so a script
> configuring `ufw` alone is enough there. AWS and Oracle both add this second
> layer, and Oracle additionally ships restrictive host iptables rules — which
> `install.sh` handles automatically.

### 3. Run the installer

Recommended — accepts clients on **any** UDP port, one line, pastes cleanly over SSH:

```bash
curl -fsSL https://raw.githubusercontent.com/KaranSinghMomi/wg-setup/main/install.sh | sudo bash -s -- --token <YOUR_BOT_TOKEN> --chat <YOUR_CHAT_ID> --ports 53 --name oracle1 --any-port
```

`--ports 53` only sets the port written into the generated config — `53` is the
one most likely to pass a restrictive network, and you can change it afterwards.
`--any-port` is what makes every other port work.

Locked to a fixed set of ports instead (no `--any-port`, so only these work):

```bash
curl -fsSL https://raw.githubusercontent.com/KaranSinghMomi/wg-setup/main/install.sh | sudo bash -s -- --token <YOUR_BOT_TOKEN> --chat <YOUR_CHAT_ID> --ports 53,9200,9201 --name oracle1
```

Prefer not to pipe a remote script into root? Download and read it first:

```bash
curl -fsSLO https://raw.githubusercontent.com/KaranSinghMomi/wg-setup/main/install.sh
less install.sh
sudo bash install.sh --token <YOUR_BOT_TOKEN> --chat <YOUR_CHAT_ID> --ports 53 --any-port
```

The config and QR code arrive in Telegram. Scan the QR with the WireGuard mobile
app, or import the `.conf` on desktop.

---

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--token <token>` | *required* | Telegram bot token |
| `--chat <id>` | *required* | Telegram chat id (negative for groups) |
| `--ports <list>` | `51820` | Comma-separated UDP ports clients may use; the first is written into new configs |
| `--any-port` | off | Accept **any** UDP port (see below) |
| `--no-any-port` | | Turn that off again on a re-run |
| `--name <name>` | public IP | Label for this server in Telegram |
| `--endpoint <ip>` | auto-detected | Override the public address |
| `--subnet <cidr>` | `10.13.13.0/24` | Tunnel subnet (must be a `/24`) |
| `--dns <servers>` | `1.1.1.1, 1.0.0.1` | DNS pushed to clients |
| `--mtu <n>` | `1420` | Client MTU |
| `--peer <name>` | `client` | Name of the peer created at install |
| `--uninstall` | | Remove config, service and helper |

Settings are saved to `/etc/wireguard/installer.env`, so a later bare re-run
reuses them. Re-running is safe: server keys and existing peers are preserved,
firewall rules are not duplicated, and no extra peer is created.

---

## Managing peers: `wg-peer`

Installed to `/usr/local/bin/wg-peer`. Run as root.

```bash
wg-peer add laptop          # create, apply live, send to Telegram
wg-peer list                # peers with handshake times and transfer
wg-peer remove laptop       # revoke immediately
wg-peer send laptop         # re-send the config to Telegram
wg-peer qr laptop           # print the QR in your terminal
wg-peer config laptop       # print the config to stdout
wg-peer render              # regenerate wg0.conf from saved state
```

Adding and removing peers takes effect **without restarting the tunnel** — other
clients stay connected.

### Accepting any port (`--any-port`)

By default only the ports in `--ports` work. With `--any-port`, **every** UDP port
reaches the server, so a client can be pointed at literally any port number:

```bash
curl -fsSL https://raw.githubusercontent.com/KaranSinghMomi/wg-setup/main/install.sh \
  | sudo bash -s -- --token ... --chat ... --ports 53,9200,9201 --any-port
```

`--ports` still decides which port new configs are generated with; `--any-port`
just means nothing else is rejected. Change `Endpoint` in the client to `:443`,
`:8080`, `:34567` — anything — and it connects with no server-side change.

**You must also open all UDP ports in your cloud firewall.** On Oracle: VCN
Security List → Add Ingress Rule → source `0.0.0.0/0`, IP Protocol **UDP**, and
leave the **destination port range empty** (which means all ports). If you only
open three there, only those three will work no matter what the server allows.

Two things worth understanding before enabling it:

- **Any other inbound UDP service on this machine would be swallowed**, because
  all UDP is handed to WireGuard. Fine on a dedicated VPN box, not fine if the
  same host also serves DNS, game traffic, VoIP, etc.
- **DHCP is deliberately exempted** (`--dport 67:68 -j RETURN`, inserted before
  the catch-all). Without that, a lease renewal reply would be redirected into
  WireGuard and the VM could lose its IP address.

Your own outbound UDP (DNS, NTP) is unaffected: netfilter's `nat` table is only
consulted for the first packet of a connection, so replies return through
conntrack and never hit the redirect. This is verified in testing.

Exposing every UDP port is less alarming than it sounds — WireGuard silently
drops anything that fails authentication, so scanners get no response and no
service fingerprint from any of those ports.

### Switching ports when one is blocked

Every configured port reaches the same server, so you can reissue an existing
peer's config against a different port. **Same keys, no revocation:**

```bash
wg-peer config laptop 9201     # print it
wg-peer send   laptop 9201     # or send it to Telegram
```

You can also just edit `Endpoint` in the client app — only the port changes.

---

## Multiple servers

Run the same command on as many servers as you like with the **same token and
chat id**. Each posts its own config, labelled by `--name` and public IP.

This works because the script only ever *sends* to Telegram. The Bot API delivers
each incoming update to exactly one reader, so several servers *polling* one bot
would steal each other's commands — but sending has no such limit. That is also
why there are no `/commands`: peer management lives in `wg-peer` on the box.

---

## How multi-port works

WireGuard binds exactly one UDP port. Rather than run several instances, the
server listens on `51820` and netfilter redirects each public port to it:

```
UDP 53   ─┐
UDP 9200 ─┼─ PREROUTING REDIRECT ──►  wg0 :51820
UDP 9201 ─┘
```

These rules live in `/etc/wireguard/wg0.conf` as `PostUp`/`PostDown`, so they are
applied when the interface comes up, removed when it goes down, and restored at
boot by systemd. Nothing else needs to persist them.

A useful side effect: **nothing ever binds port 53**, so there is no conflict with
`systemd-resolved`. It listens on `127.0.0.53:53`, and loopback traffic goes
through `OUTPUT`, not `PREROUTING` — the server keeps resolving DNS normally.

### The Oracle Cloud detail that trips people up

Oracle's Ubuntu images ship an iptables `REJECT` rule that allows only
established connections, ICMP, loopback, NTP and SSH. Opening the VCN Security
List alone is **not enough**.

Because `PREROUTING` (nat) runs *before* `INPUT` (filter), by the time a packet
reaches that REJECT its port has already been rewritten to `51820`. So the accept
rule must be for **udp/51820**, and must be **inserted above** the REJECT:

```bash
iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT   # -I, never -A
```

The script does this for you. Appending with `-A` would land *after* the REJECT
and silently do nothing — which is exactly how this fails in a way that looks
correctly configured.

---

## Troubleshooting

**Client never handshakes.**
Work outward, cloud first:

```bash
sudo systemctl status wg-quick@wg0        # is it running?
sudo wg show                              # any handshake at all?
sudo iptables -L INPUT -n --line-numbers  # is ACCEPT 51820 ABOVE any REJECT?
sudo iptables -t nat -S PREROUTING        # one REDIRECT per port?
```

Then confirm the cloud firewall (VCN Security List / NSG) allows inbound UDP.
`connection timed out` from outside usually means the cloud firewall; rules
present but no traffic usually means the host iptables ordering above.

**Telegram delivery failed.**
The server still works — only delivery failed. Fix the credentials in
`/etc/wireguard/installer.env`, then `wg-peer send <name>`. To read the config
without Telegram: `wg-peer qr <name>`.

**Tunnel connects but no internet.**

```bash
sysctl net.ipv4.ip_forward                             # must be 1
sudo iptables -t nat -S POSTROUTING | grep MASQUERADE  # must exist
```

**Check which ports are actually reachable** from another machine:

```bash
nc -zvu <server-ip> 53 9200 9201
```

---

## Security notes

- **Telegram chats are not end-to-end encrypted.** Client private keys pass
  through Telegram and are retained on their servers. For defeating port blocking
  that is a reasonable trade, but anyone with access to that chat gets every
  server's config. Treat the chat as the system's security boundary.
- **Client private keys are stored on the server** in `/etc/wireguard/peers.json`
  (mode `600`). This is what makes `wg-peer config <name> <port>` able to reissue
  a config on a different port without new keys. If you would rather not keep
  them, delete the `priv` fields — you lose only the re-send feature.
- **`curl | sudo bash` runs a remote script as root.** Pin the URL to a commit SHA
  rather than `main`, or download and read it first.
- **UDP/53 is not a disguise.** It defeats naive port-based blocking, not deep
  packet inspection, which fingerprints the WireGuard handshake regardless of
  port.

---

## Uninstall

```bash
sudo bash install.sh --uninstall
```

Stops and disables the service (which removes the firewall rules via `PostDown`),
and deletes `/etc/wireguard`, the sysctl drop-in and `wg-peer`. Installed apt
packages are left alone.

---

## Requirements

- Ubuntu or Debian, with systemd
- root / sudo
- A kernel with WireGuard (mainline ≥ 5.6; Ubuntu 20.04+ is fine). Most KVM VPSs
  qualify; OpenVZ/LXC hosts often do not. The installer checks this and stops
  early with a clear message.

Everything else — `wireguard`, `iproute2`, `iptables`, `qrencode`, `curl`, `jq` —
is installed automatically.
