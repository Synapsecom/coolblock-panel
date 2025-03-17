[![coolblock-logo-text](assets/coolblock-logo-text.svg)](https://coolblock.com?ref=github)

![Panel Web - Latest Docker Tag](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FSynapsecom%2Fcoolblock-panel%2Frefs%2Fheads%2Fmain%2Fmanifest.json&query=%24.panel-web.version&style=for-the-badge&logo=docker&label=web&color=2a74a3&link=registry.coolblock.com%2Fcoolblock%2Fpanel-web)
![Panel API - Latest Docker Tag](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FSynapsecom%2Fcoolblock-panel%2Frefs%2Fheads%2Fmain%2Fmanifest.json&query=%24.panel-api.version&style=for-the-badge&logo=docker&label=api&color=2a74a3&link=registry.coolblock.com%2Fcoolblock%2Fpanel-api)
![Panel Proxy - Latest Docker Tag](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FSynapsecom%2Fcoolblock-panel%2Frefs%2Fheads%2Fmain%2Fmanifest.json&query=%24.panel-proxy.version&style=for-the-badge&logo=docker&label=proxy&color=2a74a3&link=registry.coolblock.com%2Fcoolblock%2Fpanel-proxy)

[![Deploy VPS - Liquid Cloud](https://img.shields.io/badge/deploy%20vps-liquid%20cloud-7643c9?style=for-the-badge&logo=cloudsmith&logoColor=white)](https://portal.synapsecom.gr?ref=github)

## Getting started

1. Install latest Ubuntu Server 24.04 LTS. Please follow [this guide](INSTALLATION-ISO.md).

   > When prompted for user creation, insert `coolblock` as Full Name and Username, insert `panel` for Hostname and the password of your choice (usually `coolblock` as it will be changed later by end customer).

2. Run the bootstrap script to **install** or **upgrade** the stack:

   > The script prepares the project in /home/coolblock/panel and keeps database dumps in /home/coolblock/panel/backup. The license key is expiring every year for security and it is required to contact us for key rotation.

   ```bash
   curl -fsSL https://downloads.coolblock.com/panel/install.sh | bash -s -- --tank-model <tank_model> --plc-model <plc_model> --serial-number <serial_number> --license-key <license_key>
   ```

3. Login with the default credentials

   > MUST be changed afterwards `Gear Icon -> Change Password` and `Gear Icon -> Change PIN`

   | Username | Password | PIN  |
   | -------- | -------- | ---- |
   | admin    | admin123 | 1234 |

## Adiministration

- Services lifecycle

  ```bash
  sudo systemctl start coolblock-panel.service  # to start the services
  sudo systemctl restart coolblock-panel.service  # to restart the services
  sudo systemctl stop coolblock-panel.service  # to stop the services
  ```

- Connecting to relational database

  ```bash
  # as coolblock user
  mysql --defaults-file=~/.my.cnf coolblock-panel
  ```

- Taking backups of relational database

  ```bash
  # as coolblock user
  cd panel/
  mysqldump --defaults-file=~/.my.cnf --databases coolblock-panel > adhoc-coolblock-panel_$(date +%Y%m%d_%H%M%S).sql
  ```

- Connecting to Panel (remotely)

  > You will be prompted with username and password instead of PIN.

  Open your browser and navigate to [https://panel-pc-ip-or-fqdn](https://panel-pc-ip-or-fqdn).

- Connecting to time-series database (remotely)

  > Login with username `coolblock` and the random generated password which can be found at `DOCKER_INFLUXDB_INIT_PASSWORD` variable in `/home/coolblock/panel/.env` file.

  Open your browser and navigate to [https://panel-pc-ip-or-fqdn:8086](https://panel-pc-ip-or-fqdn:8086).

## Monitoring

The stack exposes a healthcheck endpoint at `/backend/health` that accepts an optional argument `?metrics=1` which will expose all services metrics for you.
We highly recommend you to scrape/parse this endpoint (with zabbix/nagios etc..) in order to monitor multiple installations with ease.

Example healthcheck response with telemetry disabled:

```json
{
  "redis": { "status": "healthy" },
  "database": {
    "influx": {
      "local": { "status": "healthy" },
      "cloud": { "status": "healthy" }
    },
    "mysql": { "status": "healthy" }
  },
  "panel": {
    "web": { "status": "healthy", "version": "0.9.9" },
    "api": { "status": "healthy", "version": "1.0.0" }
  },
  "internet": { "status": "healthy" },
  "latency": 442.908
}
```

> Latency value is in ms

The healthcheck endpoint should reply with http status code 200 when `redis`, local `influxdb`, `mysql` and `panel` are healthy, otherwise it responds with a 5xx status code.
