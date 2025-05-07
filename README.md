# 🔄 Docker Auto Update Script

![GitHub release (latest by date)](https://img.shields.io/github/v/release/madrugal/docker-update-script?label=Latest%20Release)
![Tested on Raspberry Pi OS](https://img.shields.io/badge/Tested%20on-Raspberry%20Pi%20OS-red?logo=raspberrypi)

This is a Bash script to automatically update and rollback standalone Docker containers or Docker Compose services.

## 📦 Features

- ✅ **Auto-update** one or more Docker containers or Compose services
- 🧠 **Automatic detection** of Compose-managed containers when using container mode
- 🔁 **Rollback support**: choose previous versions from log history
- 🧹 **Prunes old images** to free disk space
- 📝 **Log file output** for all actions (container name, image, digest, timestamp, type)
- 🎨 **Colored output** and detailed **error reporting**
- 🔒 **Safe fallback** to `/tmp/docker-update.log` if no log path is configured


---

## 🚀 Quick Start

Download and make it executable:

```bash
curl -L https://github.com/madrugal/docker-update-script/releases/latest/download/docker-update.sh -o docker-update.sh
chmod +x docker-update.sh
```

Run as you wish:

```bash
./docker-update.sh --containers my_app
./docker-update.sh --file docker-compose.yml
./docker-update.sh --rollback my_app
```

---

## ⚙️ Configuration

At the top of the script, configure the following variable to specify where the update log should be stored:

```bash
LOG_FILE=""  # e.g., /path/to/docker_update.log
```

If not set, the script will use `/tmp/docker-update.log` and notify the user on every run.

---

## 📖 Usage Examples

- 🔄 Update all Compose services:
  ```bash
  ./docker-update.sh --file docker-compose.yml
  ```

- 🎯 Update specific Compose service:
  ```bash
  ./docker-update.sh --file docker-compose.yml --service backend
  ```

- 🔧 Update standalone container to latest:
  ```bash
  ./docker-update.sh --containers redis
  ```

- 🏷️ Update container to a specific version:
  ```bash
  ./docker-update.sh --containers redis --tag 7.0
  ```

- ⏪ Rollback to a previous version:
  ```bash
  ./docker-update.sh --rollback redis
  ```

---

## 🧠 Advanced Use

- **Compose-Aware Container Updates**  
  If you use `--containers` but the container was originally launched via Docker Compose, the script will detect this and switch to the corresponding Compose file/service for updates — no manual override needed.

- **Automatic Logging**  
  The script records every update, rollback, or skipped operation to a log file with:
  - Timestamp
  - Container/Service name
  - Image (with tag/digest)
  - Action type (`UPDATE`, `ROLLBACK`, `SKIP`, or `FAIL`)

- **Rollback Menu**  
  `--rollback` shows the last few updates for a given container and lets you pick which one to revert to.

- **Port and Volume Mapping Detection**  
  When updating non-compose containers, the script preserves existing volume mounts, environment variables, ports, entrypoints, and network modes automatically.

- **Post-Update Cleanup**  
  After successful updates, unused images are pruned using:
  ```bash
  docker image prune -a -f
  ```

---

## ⚠️ Disclaimer

> ⚠️ **USE AT YOUR OWN RISK.**
>
> This script is provided **“as is”**, without warranty of any kind.  
> The author is **not responsible** for any damage, data loss, or service disruption caused by the use of this script.  
> Always test in a non-production environment first.  
> You are solely responsible for verifying the safety and suitability of this code for your systems.

---

## 📜 License

This project is released under the [CC0 1.0 Universal](LICENSE) license.  
You may use it freely, modify it, and redistribute it — without permission or attribution.

---

Made with ❤️ by [madrugal](https://github.com/madrugal)
