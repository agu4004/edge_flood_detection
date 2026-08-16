# Deploy Water Controller lên Raspberry Pi

Tài liệu này chỉ mô tả hai thành phần production: Raspberry Pi controller và
ESP32 sensor node. Source được lấy trực tiếp từ Git; không cần controller hoặc
server trung gian.

## 1. Topology

### Pi phát AP độc lập

```text
ESP32 → Wi-Fi WaterController → Raspberry Pi
                                 ├── 10.42.0.1:8000 FastAPI
                                 ├── 10.42.0.1:1883 MQTT
                                 ├── SQLite
                                 └── edge-controller.local
```

### Pi và ESP cùng Wi-Fi router

```text
Router Wi-Fi
  ├── Raspberry Pi: FastAPI + MQTT + SQLite
  ├── ESP32 water-001
  └── ESP32 water-002
```

LAN mode cần mDNS `edge-controller.local` hoạt động và router không bật client
isolation.

## 2. Chuẩn bị Raspberry Pi

Dùng Raspberry Pi OS Lite 64-bit. Trong Raspberry Pi Imager:

- tạo username/password;
- bật SSH;
- đặt WLAN country `VN`;
- cấu hình Wi-Fi router nếu sẽ dùng LAN mode.

Đăng nhập Pi rồi clone repository:

```bash
ssh admin@PI_IP
sudo apt update
sudo apt install -y git
git clone https://github.com/USER/REPOSITORY.git ~/water-controller-project
cd ~/water-controller-project
```

## 3. Firmware ESP32

Firmware production hiện tại:

```text
esp32/water_edge_node/water_edge_node.ino
```

Phiên bản 1.2.1 tìm controller theo thứ tự:

```text
edge-controller.local → WiFi.gatewayIP() → retry
```

Gateway fallback chỉ trỏ đúng Pi trong AP mode. Firmware hỗ trợ `wifi_reset`
để xóa riêng Wi-Fi nhưng giữ device ID/topic, và có Wi-Fi diagnostics cho
SSID, RSSI, kênh, auth mode cùng disconnect reason.

Có thể build/upload ngay từ Pi khi ESP32 nối USB:

```bash
arduino-cli core install esp32:esp32
arduino-cli lib install PubSubClient
arduino-cli compile --upload --port /dev/ttyUSB0 \
  --fqbn esp32:esp32:esp32 ./esp32/water_edge_node
```

## 4. Cài Pi ở chế độ phát AP

Chạy tại root repository:

```bash
sudo WATER_AP_PASSWORD='12345678' bash deploy/pi/install.sh
sudo reboot
```

Installer thực hiện:

1. cài Python, Mosquitto, Avahi và NetworkManager;
2. cài app vào `/opt/water-controller`;
3. tạo Python venv và cài dependencies;
4. cấu hình Mosquitto tại `1883`;
5. tạo AP `WaterController`, `10.42.0.1/24`, DHCP/NAT;
6. đặt hostname `edge-controller`;
7. enable `water-controller.service`.

Sau reboot:

```text
SSID       WaterController
Password   12345678
Pi IP      10.42.0.1
Dashboard  http://10.42.0.1:8000/
SSH        ssh admin@10.42.0.1
```

Kiểm tra deployment AP:

```bash
cd ~/water-controller-project
sudo bash deploy/pi/verify.sh
```

## 5. Chuyển Pi sang Wi-Fi router

Liệt kê profile NetworkManager:

```bash
nmcli connection show
```

Ưu tiên profile Wi-Fi router và tắt autoconnect AP:

```bash
sudo nmcli connection modify 'HOME_WIFI_PROFILE' \
  connection.autoconnect yes connection.autoconnect-priority 200
sudo nmcli connection modify WaterController connection.autoconnect no
```

AP unit mặc định quảng bá alias dashboard về `10.42.0.1`. Trong LAN mode,
tạo systemd override để app tự phát hiện IP:

```bash
sudo systemctl edit water-controller.service
```

Nhập:

```ini
[Service]
Environment=WATER_MDNS_ADDRESS=
```

Áp dụng:

```bash
sudo systemctl daemon-reload
sudo reboot
```

Sau reboot, lấy IP bằng router hoặc:

```bash
hostname -I
```

Dashboard:

```text
http://edge-controller.local:8000/
http://water-monitor.local:8000/
http://PI_LAN_IP:8000/
```

## 6. Provision ESP32

Với từng node fresh hoặc đã `wifi_reset`:

1. kết nối `WaterSensor-Setup`, password `12345678`;
2. mở `http://192.168.4.1/`;
3. nhập `WaterController/12345678` trong AP mode, hoặc Wi-Fi router trong LAN
   mode;
4. ESP nhận DHCP IP;
5. ESP tìm `edge-controller.local`, đăng ký FastAPI và kết nối MQTT;
6. node xuất hiện trên dashboard.

Board từng đăng ký sẽ nhận lại device ID cũ theo hardware ID nếu database Pi
vẫn còn record tương ứng.

## 7. Quản lý server

```bash
sudo systemctl status water-controller --no-pager
sudo systemctl restart water-controller
sudo systemctl status mosquitto --no-pager
sudo journalctl -u water-controller -f
sudo journalctl -u mosquitto -f
```

Health/MQTT:

```bash
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/api/devices
mosquitto_sub -h 127.0.0.1 -t 'devices/#' -v
```

## 8. Cập nhật từ Git

```bash
cd ~/water-controller-project
git pull --ff-only
sudo WATER_AP_PASSWORD='12345678' bash deploy/pi/install.sh
```

Installer giữ database live trong `/opt/water-controller/data/`. Nếu Pi đang
dùng LAN mode, installer sẽ cấu hình AP lại; đặt lại:

```bash
sudo nmcli connection modify WaterController connection.autoconnect no
sudo systemctl restart water-controller
```

## 9. Khôi phục database demo

Repository có snapshot `controller/data/water_controller.demo.db` gồm 2 node
và 1 link:

```bash
sudo systemctl stop water-controller
sudo install -o watercontroller -g watercontroller -m 0640 \
  ~/water-controller-project/controller/data/water_controller.demo.db \
  /opt/water-controller/data/water_controller.db
sudo systemctl start water-controller
```

## 10. Lưu ý prototype

Mosquitto đang dùng `allow_anonymous true`. Weather và Overpass cần Internet;
sensor, MQTT, SQLite và dashboard vẫn chạy offline trong AP mode.
