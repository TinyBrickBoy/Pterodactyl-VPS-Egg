<div align="center">

# Pterodactyl VPS Egg — Debian 13

[![License](https://img.shields.io/github/license/ysdragon/Pterodactyl-VPS-Egg?style=for-the-badge)](LICENSE)

**Lightweight Debian 13 (Trixie) VPS egg for Pterodactyl Panel with auto-generated root credentials.**

</div>

---

## What this egg does

- Installs **Debian 13 (Trixie)** automatically on first boot — no menu, no version pick.
- Generates a **random root username and password** the first time the server starts.
- Installs and starts an **SSH server** automatically, listening on the server's main IP and main port.
- Prints the credentials **once** on first boot (also stored in `/root/.vps_credentials`).
- No extra port variables, no broken port forwarding — only the one allocation that actually works.

## Supported architectures

| Arch     | Status |
|----------|--------|
| amd64    | yes    |
| arm64    | yes    |
| riscv64  | yes    |

## Quick start

1. Download `egg-vps.json` from this repo.
2. In Pterodactyl admin: **Nests → Import Egg** and upload it.
3. Create a server using the VPS egg. The default allocation (main IP + main port) is all you need.
4. Start the server. The console will print the random credentials banner on first boot:

   ```
   ╔═══════════════════════════════════════════════════════════════════════════════╗
   ║                       VPS ROOT CREDENTIALS (save now!)                        ║
   ╠═══════════════════════════════════════════════════════════════════════════════╣
   ║  Host:     10.0.0.5                                                           ║
   ║  Port:     22                                                                 ║
   ║  User:     root_a1b2c3d4                                                      ║
   ║  Password: 7xK9pQ2vN8mL4rT6sH3w                                                ║
   ╚═══════════════════════════════════════════════════════════════════════════════╝
   ```

5. **Copy the credentials now** — they are shown only once. If you miss them, run:

   ```sh
   cat /root/.vps_credentials
   ```

## Connecting

The SSH server starts automatically and listens on the server's main allocation:

```sh
ssh <user>@<host> -p <port>
```

Both values come from the Pterodactyl allocation assigned to the server.

## Files of interest

| Path                      | Purpose                                            |
|---------------------------|----------------------------------------------------|
| `/ssh_config.yml`         | SSH server configuration (user/password/port).     |
| `/root/.vps_credentials`  | Persistent copy of the generated credentials.      |
| `/autorun.sh`             | Script executed on every container start.          |

## Built-in console commands

Once the server is running you can use the Pterodactyl console:

| Command          | Description                              |
|------------------|------------------------------------------|
| `help`           | Show all available commands              |
| `status`         | System resource summary                  |
| `backup`         | Create a tarball backup of the rootfs    |
| `restore <file>` | Restore from a backup tarball            |
| `reinstall`      | Wipe and reinstall Debian 13             |
| `install-gui`    | Install desktop environment + VNC/noVNC  |
| `start-vnc`      | Start the VNC server                     |
| `start-novnc`    | Start browser-based VNC access           |
| `start-tunnel`   | Start a Cloudflare tunnel for noVNC      |
| `gui-status`     | Show GUI server status                   |
| `exit`           | Stop the container                       |

> Running `reinstall` wipes everything, regenerates random credentials, and shows them again on the next start.

## Changing credentials

Edit `/ssh_config.yml` and restart the server:

```yml
ssh:
  port: "22"
  user: "your_user"
  password: "your_password"

sftp:
  enable: true
```

`password` accepts plain text, bcrypt, or argon2 hashes.

## License

MIT — see [LICENSE](LICENSE).
