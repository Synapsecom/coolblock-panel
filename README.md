[![coolblock-logo-text](https://cdn.coolblock.com/coolblock-wide-text.svg)](https://coolblock.com?ref=github)

![Panel Web - Latest Docker Tag](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FSynapsecom%2Fcoolblock-panel%2Frefs%2Fheads%2Fmain%2Fmanifest.json&query=%24.panel-web.version&style=for-the-badge&logo=docker&label=web&color=2a74a3&link=registry.coolblock.com%2Fcoolblock%2Fpanel-web)
![Panel API - Latest Docker Tag](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FSynapsecom%2Fcoolblock-panel%2Frefs%2Fheads%2Fmain%2Fmanifest.json&query=%24.panel-api.version&style=for-the-badge&logo=docker&label=api&color=2a74a3&link=registry.coolblock.com%2Fcoolblock%2Fpanel-api)
![Panel Proxy - Latest Docker Tag](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FSynapsecom%2Fcoolblock-panel%2Frefs%2Fheads%2Fmain%2Fmanifest.json&query=%24.panel-proxy.version&style=for-the-badge&logo=docker&label=proxy&color=2a74a3&link=registry.coolblock.com%2Fcoolblock%2Fpanel-proxy)
![Panel Tunnel - Latest Docker Tag](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FSynapsecom%2Fcoolblock-panel%2Frefs%2Fheads%2Fmain%2Fmanifest.json&query=%24.panel-tunnel.version&style=for-the-badge&logo=docker&label=tunnel&color=2a74a3&link=registry.coolblock.com%2Fcoolblock%2Fpanel-tunnel)

[![Deploy VPS - Liquid Cloud](https://img.shields.io/badge/deploy%20vps-liquid%20cloud-7643c9?style=for-the-badge&logo=cloudsmith&logoColor=white)](https://portal.synapsecom.gr?ref=github)

## Getting started

1. Configure BIOS per your Mini PC model:
   1. [Beelink MINI S12 Pro (N100)](guides/bios/beelink-mini-s12-pro/configuration.md)
   2. [Advantech P1571Z-C6 V2 (6650U)](guides/bios/advantech-p1571z-c6-v2/configuration.md)
   3. [Yentek C4350Z-HD (i5-10210)](guides/bios/yentek-c4350z-hd/configuration.md)
2. Install Ubuntu Server 24.04 LTS following [this guide](guides/iso.md).
3. Run the bootstrap script to **install** or **upgrade** the stack:

   > Installs to `/home/coolblock/panel`. Database backups are stored in `/home/coolblock/panel/backup`.

   <!-- <span style="display: inline-flex; align-items: center;">
      <img src="assets/warning-blue-circle.svg" width="32" height="32" style="margin-right: 5px;">
      <strong>DO NOT INSTALL VIA SSH, USE LOCAL TTY</strong>
   </span> -->

   ```bash
   curl -fsSL https://downloads.coolblock.com/panel/install.sh \
       | bash -s -- \
           --tank-model <tank_model> \
           --plc-model <plc_model> \
           --serial-number <serial_number> \
           --license-key <license_key> \
           --tunnel-jwt <tunnel_jwt> \
       | tee /root/install.log  # specify --headless argument if tank model does not support touch panel
   ```

   > PLC model compatibility:

   | Tank Model | PLC Model                          |
   | ---------- | ---------------------------------- |
   | `x110`     | `Carel c.pCO mini (proto:modbus)`  |
   | `x520`     | `Siemens S7-1200 (proto:profinet)` |

4. Log in with default credentials

   > Change these immediately via `Gear Icon -> Change Password` and `Gear Icon -> Change PIN`

   | Username | Password | PIN  |
   | -------- | -------- | ---- |
   | admin    | admin123 | 1234 |

## Administration

- Service lifecycle

  ```bash
  sudo systemctl start coolblock-panel.service
  sudo systemctl restart coolblock-panel.service
  sudo systemctl stop coolblock-panel.service
  ```

- Connect to MySQL

  ```bash
  # as coolblock user
  mysql --defaults-file=~/.my.cnf coolblock-panel
  ```

- Back up MySQL

  ```bash
  # as coolblock user
  cd panel/
  mysqldump --defaults-file=~/.my.cnf --databases coolblock-panel > adhoc-coolblock-panel_$(date +%Y%m%d_%H%M%S).sql
  ```

- Remote Panel access

  > Prompts for username/password instead of PIN.

  Navigate to [https://panel-pc-ip-or-fqdn:10443](https://panel-pc-ip-or-fqdn:10443).

- Remote InfluxDB access

  > Username: `coolblock`. Password: value of `DOCKER_INFLUXDB_INIT_PASSWORD` in `/home/coolblock/panel/.env`.

  Navigate to [https://panel-pc-ip-or-fqdn:8086](https://panel-pc-ip-or-fqdn:8086).

## Monitoring

The stack exposes a healthcheck endpoint at `/backend/health`. Append `?metrics=1` to include service metrics.
Scrape this endpoint with Zabbix, Nagios, or similar tools to monitor multiple installations.

Example response (without metrics):

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

> Latency is in milliseconds.

Returns HTTP 200 when `redis`, local `influxdb`, `mysql`, and `panel` are healthy; 5xx otherwise.

## Troubleshooting

- `Error response from daemon: Get "https://<subhost>.coolblock.com/v2/": dial tcp: lookup <subhost>.coolblock.com on <dns-ip>:53: no such host` or `Error response from daemon: unknown: failed to resolve reference "<subhost>.coolblock.com/coolblock/panel-<component>:<version>": unexpected status from HEAD request to https://<subhost>.coolblock.com/v2/coolblock/panel-<component>/manifests/<version>: 530 <none>`

  The deployment file references the old container registry. As of **11-Nov-25**, container images are hosted on [GitHub Packages](https://github.com/orgs/synapsecom/packages).

  Fix by running:

  ```bash
  sed -i \
      -e 's#registry.coolblock.com/coolblock/panel-web#ghcr.io/synapsecom/coolblock-panel-web#' \
      -e 's#registry.coolblock.com/coolblock/panel-api#ghcr.io/synapsecom/coolblock-panel-api#' \
      -e 's#registry.coolblock.com/coolblock/panel-proxy#ghcr.io/synapsecom/coolblock-panel-proxy#' \
      -e 's#registry.coolblock.com/coolblock/panel-tunnel#ghcr.io/synapsecom/coolblock-panel-tunnel#' \
      /home/coolblock/panel/docker-compose.yml

  sudo systemctl restart coolblock-panel.service
  ```

  You may also need to update your license key (access token). Contact your system administrator.

- `proxy-1  | 2025-11-11T20:13:17Z ERR Provider error, retrying in 2.018153525s error="Error response from daemon: client version 1.24 is too old. Minimum supported API version is 1.44, please upgrade your client to a newer version" providerName=docker`

  Known bug in Docker `29.0.0` — see [traefik/traefik#12253](https://github.com/traefik/traefik/issues/12253). Fix:

  ```bash
  {
    echo "[Service]"
    echo "Environment=DOCKER_MIN_API_VERSION=1.24"
  } | sudo tee /etc/systemd/system/docker.service.d/override.conf

  sudo systemctl daemon-reload
  sudo systemctl restart docker
  ```
