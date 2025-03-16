#! /usr/bin/env bash
# Author: Sotirios Roussis <s.roussis@synapsecom.gr>

# Wait for Docker containers to have "healthy" status
# We'll poll until `docker compose ps` shows "healthy" for the service named "frontend".
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

# Copy the CA cert if needed
echo "Copying CA certificate .."
/usr/bin/sudo /usr/bin/cp -pv /home/coolblock/panel/certs/localhost.ca.crt /usr/local/share/ca-certificates/

# Update system CA certificates
echo "Updating CA certificates .."
/usr/bin/sudo /usr/sbin/update-ca-certificates

# Finally, launch selected browser in kiosk mode
case "${1:-unknown}" in
  firefox)
    echo "Launching Mozilla Firefox kiosk .."
    exec /usr/bin/firefox \
      --kiosk \
      --no-remote \
      --disable-sync \
      --disable-crash-reporter \
      --disable-pinch \
      --disable-session-crashed-bubble \
      --url "https://localhost"
    ;;
  chromium)
    echo "Launching Chromium kiosk .."
    /usr/bin/chromium-browser \
      --no-proxy-server \
      --password-store=basic \
      --no-first-run \
      --disable-translate \
      --disable-sync \
      --disable-extensions \
      --disable-infobars \
      --disable-features=TranslateUI \
      --no-default-browser-check \
      --touch-events=enabled \
      --disable-pinch \
      --disable-breakpad \
      --kiosk "https://localhost"
    ;;
  *)
    echo "ERROR: Missing argument: firefox|chromium" 1>&2
    exit 1
    ;;
esac

# The "exec" ensures that once the script finishes these steps,
# the firefox process takes over PID 1 in the service.
