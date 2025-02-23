# panel-pc

![coolblock-logo-text](assets/coolblock-logo-text.svg)

## Getting started

1. Install latest Ubuntu Desktop LTS.

2. Run the bootstrap script to **install** or **upgrade** the stack:

   > The script prepares the project in /home/coolblock/panel and keeps database dumps in /home/coolblock/panel/backup

   ```bash
   curl -fsSL https://downloads.coolblock.com/panel/install.sh | bash -s -- --tank-model <tank_model> --plc-model <plc_model> --serial-number <serial_number> --license-key <license_key>
   ```

3. Login with the default credentials

   > Should be changed afterwards `Gear Icon -> Change Password` and `Gear Icon -> Change PIN`

   ```plain
   username: admin
   password: admin123
   pin: 1234
   ```

## Adiministration

- Starting the services

  ```bash
  # as coolblock user
  cd ~/panel
  docker compose up -d
  ```

- Stopping the services

  ```bash
  # as coolblock user
  cd ~/panel
  docker compose down
  ```

- Looking up credentials

  ```bash
  # as coolblock user
  cd ~/panel
  cat .env
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

- Connecting to time-series database

  Open your browser and navigate to [https://panel-pc:8086](https://panel-pc:8086).

## Monitoring

The stack exposes a healthcheck endpoint at `/backend/health` that accepts an optional argument `?metrics=1` which will expose all services metrics for you.
We highly recommend you to scrape/parse this endpoint (with zabbix/nagios etc..) in order to monitor multiple installations with ease.

Example healthcheck response with telemetry disabled:

```json
{"redis":{"status":"healthy"},"database":{"influx":{"local":{"status":"healthy"},"cloud":{"status":"unhealthy"}},"mysql":{"status":"healthy"}},"panel":{"status":"healthy"},"internet":{"status":"healthy"},"latency":85.79100000000001}
```

The healthcheck endpoint should reply with http status code 200 when `redis`, local `influxdb`, `mysql` and `panel` are healthy, otherwise it responds with a 5xx status code.
