# panel-pc

![coolblock-logo-text](assets/coolblock-logo-text.svg)

## Getting started

1. Install latest Ubuntu Desktop LTS.

2. Run the bootstrap script:

   ```bash
   curl -fsSL https://downloads.coolblock.com/panel/install.sh | bash -s -- --tank-model <tank_model> --serial-number <serial_number> --license-key <license_key>
   ```

3. Login with the default credentials (Should be changed afterwards `Gear Icon -> Change Password` and `Gear Icon -> Change PIN`)

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

- Upgrading the services

  ```bash
  # as coolblock user
  #TODO
  ```
