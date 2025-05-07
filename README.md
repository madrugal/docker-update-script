# 🔄 Docker Auto Update Script

This is a Bash script to automatically update and rollback standalone Docker containers or Docker Compose services.

## 📦 Features

- Auto-update Docker containers and Compose services
- Detect and handle Compose-managed containers
- Rollback functionality using update logs
- Prunes old images after update
- Colored output and error reporting
- Logs all updates to a file for traceability

## 🚀 Quick Start

```bash
bash docker-update.sh --containers my_app
bash docker-update.sh --file docker-compose.yml
bash docker-update.sh --rollback my_app
```

## ⚙️ Configuration

At the top of the script, configure the following:

```bash
LOG_FILE=""  # e.g., /path/to/docker_update.log
```

If not set, the script will default to `/tmp/docker-update.log` and display a warning.

## 📖 Usage Examples

- Update all Compose services:
  ```bash
  ./docker-update.sh --file docker-compose.yml
  ```

- Update specific container to latest:
  ```bash
  ./docker-update.sh --containers web
  ```

- Update container to a specific version:
  ```bash
  ./docker-update.sh --containers redis --tag 7.0
  ```

- Rollback to a previous version:
  ```bash
  ./docker-update.sh --rollback web
  ```

## ⚠️ Disclaimer

> ⚠️ **USE AT YOUR OWN RISK.**
>
> This script is provided “as is”, without warranty of any kind.  
> The author is **not responsible** for any data loss, service downtime, or system misconfiguration caused by use of this script.  
> Always test in a safe environment before using in production.

## 📜 License

This project is released under the [CC0 1.0 Universal](LICENSE) license.  
You may use it freely, for any purpose, without attribution.

---
Made with ❤️ by [Your GitHub Username]
