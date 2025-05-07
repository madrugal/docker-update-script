# Docker Update Script 📦

A robust Bash script for updating Docker containers and Docker Compose services with detailed logging, rollback support, and execution time reporting.

## Features ✨

* **Standalone containers**: Pulls latest (or specified) image, recreates with original flags.
* **Compose services**: Updates individual services in a `docker-compose.yml`, or all services.
* **Logging**: Records timestamp, container/service name, image tag, digest, and action (`UPDATE`/`SKIP`/`FAIL`) to a log file.
* **Rollback**: Lists recent updates and lets you revert to a previous image version.
* **Error handling**: Reports errors with line numbers and commands, logs failures.
* **Execution timer**: Displays script runtime in `hh:mm:ss` format.

## Configuration 🛠

At the top of the script, adjust the following variables:

```bash
# Path to your log file (history of updates)
LOG_FILE="/path/to/your/log/docker_update.log"

# Docker Compose command (e.g., "docker-compose" or "docker compose")
DOCKER_COMPOSE_CMD="docker compose"

# Default Docker run options (e.g., detach, network settings)
DOCKER_RUN_OPTS="-d"
```

Ensure the `LOG_FILE` directory exists and is writable by the user executing the script.

## Usage 📖

```bash
# Update all services in a compose file
./docker_update.sh -f docker-compose.yml

# Update a single service in a compose file
./docker_update.sh -f docker-compose.yml -s web

# Update one or more standalone containers
./docker_update.sh -c webapi redis

# Update a single container to a specific image tag
./docker_update.sh -c my_app -t v2.1.0

# Rollback to a previous version for a container
./docker_update.sh -r my_app
```

## Examples 💡

* Update the `heimdall` service in a Compose project:

  ```bash
  ./docker_update.sh -f /home/pi/docker-ymls/project/docker-compose.yml -s heimdall
  ```

* Update two standalone containers:

  ```bash
  ./docker_update.sh -c redis postgres
  ```

* Rollback the `fluent-bit` container:

  ```bash
  ./docker_update.sh -r fluent-bit
  ```

## Contributing 🤝

Feel free to fork, submit issues, or propose pull requests. Key areas:

* Notification integrations (email, Slack, Discord)
* Enhanced flag parsing or support for additional Docker flags
* Cross-platform compatibility improvements

## License 🏷

MIT License

---

*Made with ❤️ and 🐳 by \[Your Name]*
