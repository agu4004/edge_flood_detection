#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/water-controller"
APP_USER="watercontroller"
AP_CONNECTION="WaterController"
AP_SSID="${WATER_AP_SSID:-WaterController}"
AP_INTERFACE="${WATER_AP_INTERFACE:-wlan0}"
AP_ADDRESS="10.42.0.1/24"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this installer as root: sudo bash install.sh" >&2
  exit 1
fi

if [[ -d "${SCRIPT_DIR}/controller/static" ]]; then
  SOURCE_DIR="${SCRIPT_DIR}/controller"
elif [[ -d "${SCRIPT_DIR}/../../controller/static" ]]; then
  SOURCE_DIR="$(cd -- "${SCRIPT_DIR}/../../controller" && pwd)"
else
  echo "Cannot find the packaged controller directory." >&2
  exit 1
fi

AP_PASSWORD="${WATER_AP_PASSWORD:-}"
if [[ -z "${AP_PASSWORD}" && -t 0 ]]; then
  read -r -s -p "Password for Wi-Fi ${AP_SSID} (minimum 8 characters): " AP_PASSWORD
  echo
fi
if [[ ${#AP_PASSWORD} -lt 8 || ${#AP_PASSWORD} -gt 63 ]]; then
  echo "WATER_AP_PASSWORD must contain 8 to 63 characters." >&2
  exit 1
fi

echo "[1/7] Installing Raspberry Pi packages"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-venv python3-pip \
  mosquitto mosquitto-clients \
  avahi-daemon avahi-utils curl network-manager

if ! command -v nmcli >/dev/null 2>&1; then
  echo "NetworkManager/nmcli is required." >&2
  exit 1
fi
if ! nmcli -t -f DEVICE device status | grep -Fxq "${AP_INTERFACE}"; then
  echo "Wi-Fi interface ${AP_INTERFACE} was not found." >&2
  exit 1
fi

echo "[2/7] Creating application account and directories"
if ! id "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
fi
install -d -o "${APP_USER}" -g "${APP_USER}" -m 0750 "${APP_DIR}" "${APP_DIR}/data" "${APP_DIR}/static"

echo "[3/7] Installing Water Controller application"
systemctl stop water-controller.service 2>/dev/null || true
for source_file in "${SOURCE_DIR}"/*.py "${SOURCE_DIR}/requirements.txt"; do
  install -o "${APP_USER}" -g "${APP_USER}" -m 0640 "${source_file}" "${APP_DIR}/"
done
cp -a "${SOURCE_DIR}/static/." "${APP_DIR}/static/"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/static"

SOURCE_DB="${SOURCE_DIR}/data/water_controller.db"
TARGET_DB="${APP_DIR}/data/water_controller.db"
if [[ -f "${SOURCE_DB}" ]]; then
  if [[ ! -f "${TARGET_DB}" || "${WATER_REPLACE_DATABASE:-0}" == "1" ]]; then
    if [[ -f "${TARGET_DB}" ]]; then
      BACKUP_DIR="/var/backups/water-controller/$(date -u +%Y%m%dT%H%M%SZ)"
      install -d -m 0750 "${BACKUP_DIR}"
      cp -a "${TARGET_DB}" "${BACKUP_DIR}/"
      echo "Existing database backed up to ${BACKUP_DIR}"
    fi
    install -o "${APP_USER}" -g "${APP_USER}" -m 0640 "${SOURCE_DB}" "${TARGET_DB}"
  else
    echo "Keeping the existing Pi database. Set WATER_REPLACE_DATABASE=1 to replace it."
  fi
fi

if [[ ! -x "${APP_DIR}/.venv/bin/python" ]]; then
  python3 -m venv "${APP_DIR}/.venv"
fi
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/.venv"
runuser -u "${APP_USER}" -- "${APP_DIR}/.venv/bin/python" -m pip install --upgrade pip
runuser -u "${APP_USER}" -- "${APP_DIR}/.venv/bin/python" -m pip install -r "${APP_DIR}/requirements.txt"

echo "[4/7] Configuring Mosquitto"
install -o root -g root -m 0644 \
  "${SCRIPT_DIR}/mosquitto-water-controller.conf" \
  /etc/mosquitto/conf.d/water-controller.conf

echo "[5/7] Configuring the Raspberry Pi Wi-Fi access point"
if ! nmcli -t -f NAME connection show | grep -Fxq "${AP_CONNECTION}"; then
  nmcli connection add \
    type wifi ifname "${AP_INTERFACE}" con-name "${AP_CONNECTION}" \
    autoconnect yes ssid "${AP_SSID}"
fi
nmcli connection modify "${AP_CONNECTION}" \
  connection.autoconnect yes \
  connection.autoconnect-priority 100 \
  connection.interface-name "${AP_INTERFACE}" \
  802-11-wireless.mode ap \
  802-11-wireless.band bg \
  802-11-wireless.channel 6 \
  802-11-wireless.ssid "${AP_SSID}" \
  wifi-sec.key-mgmt wpa-psk \
  wifi-sec.psk "${AP_PASSWORD}" \
  ipv4.method shared \
  ipv4.addresses "${AP_ADDRESS}" \
  ipv6.method disabled

echo "[6/7] Configuring hostname, mDNS and systemd"
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_hostname edge-controller
else
  hostnamectl set-hostname edge-controller
fi
install -o root -g root -m 0644 \
  "${SCRIPT_DIR}/water-controller.service" \
  /etc/systemd/system/water-controller.service
systemctl daemon-reload
systemctl enable NetworkManager.service mosquitto.service avahi-daemon.service water-controller.service
systemctl restart mosquitto.service avahi-daemon.service water-controller.service

echo "[7/7] Installation complete"
echo
echo "The access point is configured but has not been activated during this SSH session."
echo "Reboot the Pi, then connect to:"
echo "  SSID:      ${AP_SSID}"
echo "  Pi IP:     10.42.0.1"
echo "  Dashboard: http://water-monitor.local:8000/"
echo "  ESP32:     edge-controller.local or DHCP gateway 10.42.0.1"
echo
echo "Run: sudo reboot"
