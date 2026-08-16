#!/usr/bin/env bash
set -u

failures=0

check_service() {
  local service="$1"
  if systemctl is-active --quiet "${service}"; then
    echo "[OK] ${service} is active"
  else
    echo "[FAIL] ${service} is not active"
    failures=$((failures + 1))
  fi
}

check_service NetworkManager.service
check_service mosquitto.service
check_service avahi-daemon.service
check_service water-controller.service

if ip -4 -o address show dev wlan0 | grep -q '10\.42\.0\.1/24'; then
  echo "[OK] wlan0 owns 10.42.0.1/24"
else
  echo "[FAIL] wlan0 does not own 10.42.0.1/24"
  failures=$((failures + 1))
fi

if curl --fail --silent --show-error http://127.0.0.1:8000/health; then
  echo
  echo "[OK] FastAPI health endpoint"
else
  echo "[FAIL] FastAPI health endpoint"
  failures=$((failures + 1))
fi

if mosquitto_pub -h 127.0.0.1 -p 1883 -t water-controller/verify -m ok; then
  echo "[OK] Mosquitto accepts local messages"
else
  echo "[FAIL] Mosquitto publish test"
  failures=$((failures + 1))
fi

echo
nmcli -f NAME,TYPE,DEVICE connection show --active
echo
echo "Dashboard: http://water-monitor.local:8000/"
echo "Fallback:  http://10.42.0.1:8000/"

exit "${failures}"

