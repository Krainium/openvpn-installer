# 🔐🌐 openvpn-setup

A single Bash script that installs a full OpenVPN server on any Ubuntu or Debian VPS. It builds the PKI from scratch, signs all certificates, configures the server, sets up NAT, opens the firewall, starts the service. When it finishes it hands you a `.ovpn` file ready to import into any OpenVPN client.

```bash
git clone https://github.com/krainium/openvpn-installer
cd openvpn-installer
sudo bash openvpn-setup.sh
```

---

## 🎯 What it does

The script detects your OS, installs OpenVPN together with easy-rsa 3, builds an ECC certificate authority, signs a server certificate, generates a TLS-crypt key, writes the server config, enables IP forwarding, configures NAT, starts the service. It also generates the first client `.ovpn` file the moment setup completes.

No manual PKI steps. No editing config files by hand.

---

## ⚙️ Setup walkthrough

Run the script as root. It asks four questions then does the rest on its own.

**Public IP** — it detects this automatically. Press Enter to confirm or type a different one if you are behind NAT.

**Protocol**
```
1  UDP  — faster, lower latency, recommended for most setups
2  TCP  — use this when UDP is blocked by the network or ISP
```

**Port** — defaults to `1194` for UDP or `443` for TCP. Change it to anything you prefer.

**DNS** — pick what your VPN clients will use for name resolution.
```
1  Google         8.8.8.8 / 8.8.4.4
2  Cloudflare     1.1.1.1 / 1.0.0.1
3  OpenDNS        208.67.222.222 / 208.67.220.220
4  Quad9          9.9.9.9 / 149.112.112.112
5  AdGuard        94.140.14.14 / 94.140.15.15
6  System         reads from /etc/resolv.conf
```

After you answer those, the script runs without any more input. Certificate generation takes a minute or two. At the end it prompts for a client name, generates the `.ovpn` file, prints the path.

---

## 📋 Management menu

Run the script again any time to open the menu.

```
  1  👤  Add Client       generates a new .ovpn file
  2  🗑   Remove Client    revokes the certificate, deletes the config
  3  📋  List Clients      shows all .ovpn files with their paths
  4  📊  Status            service status + currently connected clients
  5  🔄  Restart OpenVPN   restarts the server without full reinstall
  6  🗑   Uninstall         removes everything — asks you to type YES first
  0  ❌  Exit
```

---

## 📁 Where things live

| Path | What is it |
|------|------------|
| `/root/openvpn-setup/clients/` | All generated `.ovpn` files |
| `/etc/openvpn/server/server.conf` | Server config |
| `/etc/openvpn/easy-rsa/pki/` | CA, server cert, client certs, CRL |
| `/etc/openvpn-setup/state.conf` | Saved setup values |
| `/var/log/openvpn/openvpn.log` | Server log |
| `/var/log/openvpn/status.log` | Connected clients live view |

---

## 📱 Compatible clients

| Client | Platform |
|--------|----------|
| OpenVPN Connect | Windows · macOS · Android · iOS |
| OpenVPN for Android | Android |
| Tunnelblick | macOS |
| NordVPN (custom) | any platform via `.ovpn` import |

Import the `.ovpn` file directly. No extra settings needed — the certificate, key, CA root certificate are all embedded inside it.

---

## 🔒 Security details

The PKI uses elliptic curve cryptography with the `prime256v1` curve instead of RSA. No Diffie-Hellman parameters are needed. The TLS control channel is protected with a tls-crypt key so the server does not respond to unauthenticated packets at all. Data is encrypted with AES-256-GCM.

---

## 🛠 Troubleshooting

**Client connects but no internet**
```bash
systemctl status openvpn-server@server
cat /proc/sys/net/ipv4/ip_forward   # should print 1
iptables -t nat -L POSTROUTING -n   # should show a MASQUERADE rule
```

**Certificate verify failed on the client**
Open the `.ovpn` file in a text editor. Check that the `<ca>` block contains a full PEM certificate starting with `-----BEGIN CERTIFICATE-----`. If the block is empty or cut off, regenerate the client with option `1` from the menu.

**OpenVPN not starting after reboot**
```bash
systemctl enable openvpn-server@server
systemctl start  openvpn-server@server
journalctl -u openvpn-server@server -n 50 --no-pager
```

**Port blocked by ISP**
Switch to TCP on port 443. Reinstall using option `6` to uninstall first, then rerun the script and pick TCP when asked.
