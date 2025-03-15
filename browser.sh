#! /usr/bin/env bash
# Author: Sotirios Roussis <s.roussis@synapsecom.gr>

#
# This script:
#   1. Waits for the Docker containers to become healthy.
#   2. Copies the localhost CA certificate.
#   3. Updates system CA certificates.
#   4. Starts Firefox in kiosk mode.

# 0) Wait for Docker containers to have "healthy" status
#    We'll poll until `docker compose ps` shows "healthy" for the service named "frontend".
echo "Waiting for Docker container 'frontend' to be healthy .."
while /usr/bin/true; do
    if /usr/bin/docker compose -f /home/coolblock/panel/docker-compose.yml ps \
        | /usr/bin/grep -i frontend \
        | /usr/bin/grep -iv database \
        | /usr/bin/grep -iq "(healthy)"; then
        break
    fi
    sleep 5
done
echo "Docker container 'frontend' is healthy"

# 1) Copy the CA cert if needed
echo "Copying CA certificate .."
/usr/bin/sudo /usr/bin/cp -pv /home/coolblock/panel/certs/localhost.ca.crt /usr/local/share/ca-certificates/

# 2) Update CA certificates
echo "Updating CA certificates .."
/usr/bin/sudo /usr/sbin/update-ca-certificates

# 3) Finally, launch Mozilla Firefox in kiosk mode
echo "Launching Mozilla Firefox kiosk .."
exec /usr/bin/firefox \
  --kiosk \
  --no-remote \
  --disable-sync \
  --disable-crash-reporter \
  --disable-pinch \
  --disable-session-crashed-bubble \
  --url "https://localhost"

# The "exec" ensures that once the script finishes these steps,
# the firefox process takes over PID 1 in the service.
