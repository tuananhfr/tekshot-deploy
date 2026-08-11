#!/usr/bin/env bash
# ============================================================
# Tekshot AI — Universal Provisioning Script (V2.3 - Multi-OS, v1/v2)
# ============================================================
# Usage:  bash setup.sh [--v2] [TARGET_OS] <DEVICE_ID> <TYPE>
#
#   --v2        Sinh cấu hình cho backend v2 (ảnh tekshot-ai-v2-*:beta).
#               Bỏ trống = v1 (ảnh tekshot-ai-*:stable), hành vi cũ y nguyên.
#
#   DEVICE_ID must start with:
#     - pi*  (for Raspberry Pi - ARM64 Native)
#     - win* (for Windows - AMD64 TensorRT via Docker Desktop)
#
#   TYPE: all | timelapse  (default: all)
#
# Examples:
#   bash setup.sh pi4 all
#   bash setup.sh win-store1 timelapse
#   bash setup.sh --v2 pi pi4 all
# ============================================================

set -euo pipefail

# ── Constants ────────────────────────────────────────────────
readonly VERSION="2.3.0"
readonly DOMAIN_BASE="tekshot-ai.erpcons.vn"

# Note: Git Bash for Windows converts /c/ to C:\ automatically.
readonly BASE_DIR="${PWD}/tekshot-run"
readonly FRP_SERVER="36.50.54.183"
readonly FRP_PORT=7000
readonly FRP_TOKEN="123456"
readonly UPDATE_TOKEN="tekshot-ai-2026"
readonly WATCHTOWER_TOKEN="changeme"

# ── Logging ──────────────────────────────────────────────────
log()  { printf '\033[0;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()   { printf '\033[0;32m  ✔ %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[1;33m  ⚠ %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[0;31m  ✘ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Tekshot AI Universal Setup v${VERSION}

Usage:  bash setup.sh [--v2] [TARGET_OS] <DEVICE_ID> <TYPE>

  --v2        Generate for the v2 backend (tekshot-ai-v2-*:beta images)
  DEVICE_ID   Unique device id (must start with 'pi' or 'win')
  TYPE        all | timelapse  (default: all)

Examples:
  bash setup.sh pi4 all
  bash setup.sh win-store1 timelapse
  bash setup.sh --v2 pi pi4 all
USAGE
  exit 1
}

# Dòng nào chỉ chứa sentinel này thì bị xoá khỏi file đầu ra. Đó là cách một
# mảnh compose "rỗng" biến mất hẳn thay vì để lại dòng trắng giữa danh sách
# volumes — YAML vẫn hợp lệ, nhưng file sinh ra là thứ người khác phải đọc.
readonly DROP='#@DROP@'

write_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  # Dùng tr -d '\r' để dọn dẹp sạch sẽ tàn dư CRLF của Windows
  # Điều này giúp nội dung file xuất ra luôn chuẩn Linux (LF)
  tr -d '\r' | sed "/^${DROP}\$/d" > "$path"
  ok "$(basename "$path")"
}

# ── Parse Arguments ──────────────────────────────────────────
# Support both formats:
# 1. New Format (Explicit OS): bash setup.sh win pi4 all
# 2. Old Format (Implicit Pi): bash setup.sh pi4 all

# --v2 gỡ ra trước, ở bất kỳ vị trí nào, để hai định dạng positional bên dưới
# không phải biết tới nó.
EDITION="v1"
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --v2) EDITION="v2" ;;
    --v1) EDITION="v1" ;;
    *)    ARGS+=("$arg") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
readonly EDITION

if [[ "${1:-}" == "win" || "${1:-}" == "pi" ]]; then
  TARGET_OS="$1"
  PI_ID="${2:-}"
  TYPE="${3:-all}"
else
  TARGET_OS="pi"
  PI_ID="${1:-}"
  TYPE="${2:-all}"
fi

[[ -z "$PI_ID" ]] && usage
TYPE="${TYPE,,}"
[[ "$TYPE" =~ ^(all|timelapse)$ ]] || fail "Invalid type '${TYPE}'. Expected: all | timelapse"

# Đảm bảo DOMAIN bắt buộc phải theo chuẩn pi* mà sếp đã mua
[[ "$PI_ID" == pi* ]] || warn "Tên miền không bắt đầu bằng 'pi' (Ví dụ: pi4). Bạn đang dùng: $PI_ID"

readonly DOMAIN="${PI_ID}.${DOMAIN_BASE}"
readonly APP_TYPE=$([[ "$TYPE" == "all" ]] && echo "ALL" || echo "TIMELAPSE")
readonly ENABLE_AI_FACE=$([[ "$TYPE" == "all" ]] && echo "true" || echo "false")

DOCKER_IMAGE=""
FRPC_LOCAL_IP="127.0.0.1"
INFERENCE_BACKEND="hailo"

# Tên ảnh theo edition. v1 dùng :stable — tag mà Watchtower trên thiết bị đang
# theo dõi. v2 dùng :beta, tag không ai theo dõi, nên một máy cài v2 sẽ không
# bao giờ tự nhảy phiên bản.
image_ref() {
  local variant="$1"   # pi | onnx | tensorrt | tensorrt10
  local name tag
  if [[ "$EDITION" == "v2" ]]; then
    name="tekshot-ai-v2"; tag="beta"
  else
    name="tekshot-ai";    tag="stable"
  fi
  [[ "$variant" != "pi" ]] && name="${name}-${variant}"
  echo "ghcr.io/tuananhfr/${name}:${tag}"
}

# ── GPU Auto-Detection (Windows) ─────────────────────────────
detect_gpu_image() {
  if ! command -v nvidia-smi &>/dev/null; then
    warn "nvidia-smi not found. Falling back to ONNX (CPU-only)."
    image_ref onnx
    return
  fi

  local cc
  cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits 2>/dev/null | head -1)

  if [[ -z "$cc" ]]; then
    warn "Could not detect GPU Compute Capability. Falling back to ONNX."
    image_ref onnx
    return
  fi

  local major="${cc%%.*}"
  ok "Detected GPU Compute Capability: ${cc} (major=${major})"

  if (( major >= 8 )); then
    ok "GPU supports TensorRT 10 (Ampere/Ada/Blackwell)"
    image_ref tensorrt10
  else
    ok "GPU supports TensorRT 8 (Pascal/Volta/Turing)"
    image_ref tensorrt
  fi
}

if [[ "$TARGET_OS" == "pi" ]]; then
  DOCKER_IMAGE=$(image_ref pi)
  FRPC_LOCAL_IP="127.0.0.1"
elif [[ "$TARGET_OS" == "win" ]]; then
  DOCKER_IMAGE=$(detect_gpu_image)
  FRPC_LOCAL_IP="host.docker.internal"
fi

# Suy backend NGƯỢC TỪ TÊN ẢNH, không lấy từ trong detect_gpu_image.
# `DOCKER_IMAGE=$(detect_gpu_image)` chạy hàm trong subshell, nên mọi phép gán
# INFERENCE_BACKEND bên trong nó biến mất lúc trả về — biến ở ngoài vẫn là
# "hailo" kể cả trên máy Windows. Đây là lý do compose của v1 phải hardcode
# `INFERENCE_BACKEND=tensorrt`, và cũng là lý do một máy Blackwell nhận ảnh
# tensorrt10 nhưng lại được bảo chạy backend tensorrt 8.
case "$DOCKER_IMAGE" in
  *-tensorrt10:*) INFERENCE_BACKEND="tensorrt10" ;;
  *-tensorrt:*)   INFERENCE_BACKEND="tensorrt"   ;;
  *-onnx:*)       INFERENCE_BACKEND="onnx"       ;;
  *)              INFERENCE_BACKEND="hailo"      ;;
esac
log "Image: ${DOCKER_IMAGE} (edition=${EDITION}, backend=${INFERENCE_BACKEND})"

cat <<BANNER

╔══════════════════════════════════════════╗
║     Tekshot AI — Universal Setup         ║
╠══════════════════════════════════════════╣
║  Device : ${PI_ID}
║  Edition: ${EDITION} (backend: ${INFERENCE_BACKEND})
║  Target : ${TARGET_OS^^} (Docker Image: ${DOCKER_IMAGE})
║  App    : ${APP_TYPE} (Face AI: ${ENABLE_AI_FACE})
║  Domain : ${DOMAIN}
║  Folder : ${BASE_DIR}
╚══════════════════════════════════════════╝

BANNER

# ═════════════════════════════════════════════════════════════
# Phase 1 — OS & Docker Config
# ═════════════════════════════════════════════════════════════
log "Phase 1: Environment Checks"

if [[ "$TARGET_OS" == "pi" ]]; then
  if command -v docker &>/dev/null; then
    ok "Docker installed"
  else
    log "Installing Docker on Linux..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER" || true
    ok "Docker installed"
  fi
else
  # Windows Check
  if command -v docker &>/dev/null; then
    ok "Docker Desktop for Windows detected"
  else
    fail "Docker Desktop must be installed manually on Windows before running this script!"
  fi
fi

# ═════════════════════════════════════════════════════════════
# Phase 2 — Directories
# ═════════════════════════════════════════════════════════════
log "Phase 2: Directory scaffold"
mkdir -p "${BASE_DIR}"/{frpc,mediamtx,tekshot-core/data/recordings}
if [[ "$EDITION" == "v2" ]]; then
  mkdir -p "${BASE_DIR}"/{nginx,go2rtc}
fi
ok "Directories ready"

# MediaMTX custom Dockerfile — cài tzdata để Go runtime nhận biến TZ
# Không có package này, MediaMTX sẽ lưu recordings theo UTC thay vì giờ local
write_file "${BASE_DIR}/mediamtx/Dockerfile" <<'MTXDOCKERFILE'
FROM bluenviron/mediamtx:latest-ffmpeg
USER root
RUN apk add --no-cache tzdata
ENTRYPOINT [ "/mediamtx" ]
MTXDOCKERFILE

# ═════════════════════════════════════════════════════════════
# Phase 3 — App Config
# ═════════════════════════════════════════════════════════════
log "Phase 3: App config"

if [[ "$EDITION" == "v2" ]]; then
  # ENABLE_AI_FACE / UPDATE_TOKEN / WATCHTOWER_* không tồn tại trong
  # Settings của v2. Settings đặt extra="ignore" nên chúng không làm app chết,
  # nhưng viết ra thì người đọc .env sẽ tưởng chúng còn tác dụng.
  #
  # Ba đường dẫn thì để mặc định là đúng, đừng ghi đè: DB_PATH → /app/temp,
  # RECORDINGS_DIR → /app/data/recordings, MEDIAMTX_RECORD_BASE → /recordings.
  # Cả ba đều khớp volume trong compose bên dưới.
  write_file "${BASE_DIR}/tekshot-core/.env" <<EOF
HOST=0.0.0.0
PORT=5005
APP_TYPE=${APP_TYPE}
INFERENCE_BACKEND=${INFERENCE_BACKEND}
EOF

  # go2rtc KHÔNG được bật auth cho API. Go2RTCClient của v2 chỉ nhận
  # base_url + timeout, không có tham số credential nào — bật username/password
  # (như go2rtc.yaml của v1 đang có) là mọi lệnh gọi ăn 401, sync_all fail, và
  # lifespan chỉ log rồi đi tiếp: camera không bao giờ tới go2rtc trong khi
  # /system/health vẫn xanh.
  write_file "${BASE_DIR}/go2rtc/go2rtc.yaml" <<'EOF'
api:
  listen: :1984

streams:
EOF

  # Một cổng vào duy nhất, giống bản v1 đang chạy trên Pi.
  write_file "${BASE_DIR}/nginx/nginx.conf" <<'EOF'
server {
    listen 8090;

    location /go2rtc/ {
        proxy_pass http://127.0.0.1:1984/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location / {
        proxy_pass http://127.0.0.1:5005/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF
else
  write_file "${BASE_DIR}/tekshot-core/.env" <<EOF
HOST=0.0.0.0
PORT=5005
APP_TYPE=${APP_TYPE}
ENABLE_AI_FACE=${ENABLE_AI_FACE}
UPDATE_TOKEN=${UPDATE_TOKEN}
WATCHTOWER_URL=http://localhost:8080
WATCHTOWER_TOKEN=${WATCHTOWER_TOKEN}
EOF

  # config.yaml chỉ có ở v1 — nhánh v2-rebuild đã xoá file này khỏi repo.
  write_file "${BASE_DIR}/tekshot-core/config.yaml" <<'EOF'
timelapse:
  interval_seconds: 48
  cycle_hours: 24
  start_hour: 1
EOF
fi

write_file "${BASE_DIR}/mediamtx.yml" <<'EOF'
logLevel: info
api: yes
apiAddress: :9997

# Cấp quyền cho container tekshot-core gọi API đẩy cấu hình ghi hình
authMethod: internal
authInternalUsers:
  - user: any
    permissions:
      - action: api
      - action: publish
      - action: read
      - action: playback

webrtc: no
rtsp: no
rtmp: no
hls: no
srt: no
paths:
  all_others:
EOF

# ═════════════════════════════════════════════════════════════
# Phase 4 — FRP Tunnel
# ═════════════════════════════════════════════════════════════
log "Phase 4: FRP tunnel"

write_file "${BASE_DIR}/frpc/frpc.toml" <<EOF
serverAddr = "${FRP_SERVER}"
serverPort = ${FRP_PORT}
auth.method = "token"
auth.token  = "${FRP_TOKEN}"

[[proxies]]
name          = "camera-backend-${PI_ID}"
type          = "http"
localIP       = "${FRPC_LOCAL_IP}"
localPort     = 5005
customDomains = ["${DOMAIN}"]

[[proxies]]
name          = "camera-go2rtc-${PI_ID}"
type          = "http"
localIP       = "${FRPC_LOCAL_IP}"
localPort     = 1984
customDomains = ["go2rtc.${DOMAIN}"]
EOF

# ═════════════════════════════════════════════════════════════
# Phase 5 — Docker Compose Generation
# ═════════════════════════════════════════════════════════════
log "Phase 5: Generating docker-compose.yml for ${TARGET_OS^^} (${EDITION})"

# ── Mảnh compose khác nhau giữa hai edition ──────────────────
# Giữ MỘT template cho mỗi OS thay vì nhân đôi thành bốn: hai bản sao của cùng
# một file YAML 80 dòng sẽ lệch nhau ngay lần sửa thứ hai.
# Biến rỗng nở ra thành dòng trắng trong YAML — hợp lệ, không cần xử lý gì thêm.
if [[ "$EDITION" == "v2" ]]; then
  CONFIG_MOUNT="${DROP}"
  # v1 còn mount /usr/lib/libhailort.so. Bỏ có chủ đích: file đó KHÔNG tồn tại
  # trên host, nên docker đã tự tạo nó thành một thư mục rỗng ở /usr/lib và để
  # lại đó tới giờ. Loader chỉ cần libhailort.so.4, mà base image v2 đã symlink
  # sẵn tới file .4.23.0 được mount ngay dưới.
  HAILO_SO_MOUNT="${DROP}"
  HEALTH_TEST='["CMD", "curl", "-f", "http://localhost:5005/api/v1/system/health"]'
  # :beta không ai theo dõi, nhưng khoá thêm một lớp nữa: POLL_INTERVAL=0 nghĩa
  # là Watchtower không tự quét bao giờ, chỉ cập nhật khi có người gọi HTTP API.
  WATCHTOWER_POLL="      - WATCHTOWER_POLL_INTERVAL=0"
  # INFERENCE_BACKEND đã nằm trong .env của v2 — không lặp lại ở đây.
  BACKEND_ENV_WIN="${DROP}"
  GO2RTC_VOLUMES="    volumes:
      - ./go2rtc/go2rtc.yaml:/config/go2rtc.yaml"
  # Engine TensorRT không được ship trong ảnh (gắn chặt với một kiến trúc GPU),
  # nên _build_engine phải JIT ở lần chạy đầu. Mount RW thì engine sống qua các
  # lần tạo lại container, không thì lần nào cũng build lại từ đầu.
  MODELS_MOUNT_WIN="      - ./tekshot-core/models:/app/models"
  NGINX_SERVICE="
  nginx:
    image: nginx:alpine
    container_name: nginx-router
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - tekshot-core
      - go2rtc"
else
  CONFIG_MOUNT="      - ./tekshot-core/config.yaml:/app/config.yaml"
  HAILO_SO_MOUNT="      - /usr/lib/libhailort.so:/usr/lib/libhailort.so:ro"
  HEALTH_TEST='["CMD", "curl", "-f", "http://localhost:5005/"]'
  WATCHTOWER_POLL="${DROP}"
  BACKEND_ENV_WIN="      - INFERENCE_BACKEND=tensorrt"
  GO2RTC_VOLUMES="${DROP}"
  MODELS_MOUNT_WIN="${DROP}"
  NGINX_SERVICE="${DROP}"
fi

if [[ "$TARGET_OS" == "win" ]]; then
# ==================== WINDOWS DOCKER COMPOSE ====================
write_file "${BASE_DIR}/docker-compose.yml" <<EOF
services:
  tekshot-core:
    image: ${DOCKER_IMAGE}
    container_name: tekshot-core
    restart: unless-stopped
    ports:
      - "5005:5005"
    env_file:
      - ./tekshot-core/.env
    environment:
      - TZ=Asia/Ho_Chi_Minh
${BACKEND_ENV_WIN}
      - TRT_PRECISION=fp16
      - GO2RTC_URL=http://go2rtc:1984
      - MEDIAMTX_URL=http://mediamtx:9997
      - MEDIAMTX_RTSP_HOST=go2rtc
    volumes:
      - ./tekshot-core/timelapse:/app/timelapse
      - ./tekshot-core/temp:/app/temp
      - ./tekshot-core/logs:/app/logs
${CONFIG_MOUNT}
${MODELS_MOUNT_WIN}
      - ./tekshot-core/data:/app/data
    depends_on:
      - go2rtc
      - mediamtx
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
    healthcheck:
      test: ${HEALTH_TEST}
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  frpc:
    image: snowdreamtech/frpc:latest
    container_name: frpc
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./frpc/frpc.toml:/etc/frp/frpc.toml:ro
    depends_on:
      - tekshot-core

  go2rtc:
    image: alexxit/go2rtc:latest
    container_name: go2rtc
    restart: unless-stopped
    ports:
      - "1984:1984"
      - "8555:8555"
      - "8555:8555/udp"
${GO2RTC_VOLUMES}

  mediamtx:
    build: ./mediamtx
    container_name: mediamtx
    restart: unless-stopped
    environment:
      - TZ=Asia/Ho_Chi_Minh
      - MTX_WEBRTC=no
      - MTX_API=yes
      - MTX_APIADDRESS=:9997
    ports:
      - "8554:8554"
      - "9997:9997"
    volumes:
      - ./mediamtx.yml:/mediamtx.yml:ro
      - ./tekshot-core/data/recordings:/recordings

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    environment:
      - DOCKER_API_VERSION=1.43
      - WATCHTOWER_HTTP_API_UPDATE=true
      - WATCHTOWER_HTTP_API_TOKEN=${WATCHTOWER_TOKEN}
      - WATCHTOWER_LABEL_ENABLE=true
      - WATCHTOWER_CLEANUP=true
${WATCHTOWER_POLL}
      - TZ=Asia/Ho_Chi_Minh
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "127.0.0.1:8080:8080"
EOF

# nginx-router cố ý KHÔNG có ở bản Windows: nó dùng network_mode: host, thứ mà
# Docker Desktop for Windows không hỗ trợ, và proxy_pass tới 127.0.0.1 trong
# container thì cũng không với tới service khác được.

elif [[ "$TARGET_OS" == "pi" ]]; then
# ==================== RASPBERRY PI DOCKER COMPOSE ====================
write_file "${BASE_DIR}/docker-compose.yml" <<EOF
services:
  tekshot-core:
    image: ${DOCKER_IMAGE}
    container_name: tekshot-core
    restart: unless-stopped
    network_mode: host
    devices:
      - /dev/hailo0:/dev/hailo0
    env_file:
      - ./tekshot-core/.env
    environment:
      - TZ=Asia/Ho_Chi_Minh
    volumes:
      - ./tekshot-core/timelapse:/app/timelapse
      - ./tekshot-core/temp:/app/temp
      - ./tekshot-core/logs:/app/logs
${CONFIG_MOUNT}
      - ./tekshot-core/data:/app/data
      - /usr/lib/python3/dist-packages/hailo_platform:/usr/lib/python3/dist-packages/hailo_platform:ro
      - /usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:ro
${HAILO_SO_MOUNT}
      - /usr/lib/libhailort.so.4.23.0:/usr/lib/libhailort.so.4.23.0:ro
    depends_on:
      - go2rtc
      - mediamtx
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
    healthcheck:
      test: ${HEALTH_TEST}
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  frpc:
    image: snowdreamtech/frpc:latest
    container_name: frpc
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./frpc/frpc.toml:/etc/frp/frpc.toml:ro
    depends_on:
      - tekshot-core

  go2rtc:
    image: alexxit/go2rtc:latest
    container_name: go2rtc
    restart: unless-stopped
    network_mode: host
${GO2RTC_VOLUMES}

  mediamtx:
    build: ./mediamtx
    container_name: mediamtx
    restart: unless-stopped
    network_mode: host
    environment:
      - TZ=Asia/Ho_Chi_Minh
    volumes:
      - ./mediamtx.yml:/mediamtx.yml:ro
      - ./tekshot-core/data/recordings:/recordings

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    environment:
      - DOCKER_API_VERSION=1.43
      - WATCHTOWER_HTTP_API_UPDATE=true
      - WATCHTOWER_HTTP_API_TOKEN=${WATCHTOWER_TOKEN}
      - WATCHTOWER_LABEL_ENABLE=true
      - WATCHTOWER_CLEANUP=true
${WATCHTOWER_POLL}
      - TZ=Asia/Ho_Chi_Minh
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "127.0.0.1:8080:8080"
${NGINX_SERVICE}
EOF
fi

# Loại bỏ Timelapse services nếu không cấu hình "all"
if [[ "$TYPE" != "all" ]]; then
  log "Trimming unavailable services for type: ${TYPE}"
  # For safety, no services to trim right now without extra logic
fi

# ═════════════════════════════════════════════════════════════
# Phase 6 — Launch Check
# ═════════════════════════════════════════════════════════════
cat <<DONE

╔══════════════════════════════════════════╗
║          ✅  Setup Complete              ║
╠══════════════════════════════════════════╣
║                                          ║
║  Đã thiết lập xong vào thư mục:          ║
║  ${BASE_DIR}                   ║
║                                          ║
║  Edition: ${EDITION} — ${INFERENCE_BACKEND}
║  Mọi luồng dữ liệu cho (${TARGET_OS^^})       ║
║  đã tự động được cấu hình khớp nối 100%  ║
║                                          ║
╠──────────────────────────────────────────╣
║  [TIẾP THEO] Hãy nổ máy Server bằng lệnh:║
║  cd ${BASE_DIR}                ║
║  docker login ghcr.io -u tuananhfr       ║
║  docker compose up -d                    ║
╚══════════════════════════════════════════╝

DONE
