#!/usr/bin/env bash
# ============================================================
# Tekshot AI — Universal Provisioning Script (V2.2 - Multi-OS)
# ============================================================
# Usage:  bash setup.sh <DEVICE_ID> <TYPE>
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
# ============================================================

set -euo pipefail

# ── Constants ────────────────────────────────────────────────
readonly VERSION="2.2.0"
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

Usage:  bash setup.sh <DEVICE_ID> <TYPE>

  DEVICE_ID   Unique device id (must start with 'pi' or 'win')
  TYPE        all | timelapse  (default: all)

Examples:
  bash setup.sh pi4 all
  bash setup.sh win-store1 timelapse
USAGE
  exit 1
}

write_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  # Dùng tr -d '\r' để dọn dẹp sạch sẽ tàn dư CRLF của Windows
  # Điều này giúp nội dung file xuất ra luôn chuẩn Linux (LF)
  tr -d '\r' > "$path"
  ok "$(basename "$path")"
}

# ── Parse Arguments ──────────────────────────────────────────
# Support both formats:
# 1. New Format (Explicit OS): bash setup.sh win pi4 all
# 2. Old Format (Implicit Pi): bash setup.sh pi4 all

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

# ── GPU Auto-Detection (Windows) ─────────────────────────────
detect_gpu_image() {
  if ! command -v nvidia-smi &>/dev/null; then
    warn "nvidia-smi not found. Falling back to ONNX (CPU-only)."
    echo "ghcr.io/tuananhfr/tekshot-ai-onnx:stable"
    INFERENCE_BACKEND="onnx"
    return
  fi

  local cc
  cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits 2>/dev/null | head -1)

  if [[ -z "$cc" ]]; then
    warn "Could not detect GPU Compute Capability. Falling back to ONNX."
    echo "ghcr.io/tuananhfr/tekshot-ai-onnx:stable"
    INFERENCE_BACKEND="onnx"
    return
  fi

  local major="${cc%%.*}"
  ok "Detected GPU Compute Capability: ${cc} (major=${major})"

  if (( major >= 8 )); then
    ok "GPU supports TensorRT 10 (Ampere/Ada/Blackwell)"
    echo "ghcr.io/tuananhfr/tekshot-ai-tensorrt10:stable"
    INFERENCE_BACKEND="tensorrt10"
  else
    ok "GPU supports TensorRT 8 (Pascal/Volta/Turing)"
    echo "ghcr.io/tuananhfr/tekshot-ai-tensorrt:stable"
    INFERENCE_BACKEND="tensorrt"
  fi
}

if [[ "$TARGET_OS" == "pi" ]]; then
  DOCKER_IMAGE="ghcr.io/tuananhfr/tekshot-ai:stable"
  FRPC_LOCAL_IP="127.0.0.1"
  INFERENCE_BACKEND="hailo"
elif [[ "$TARGET_OS" == "win" ]]; then
  DOCKER_IMAGE=$(detect_gpu_image)
  FRPC_LOCAL_IP="host.docker.internal"
  log "Auto-selected image: $DOCKER_IMAGE (backend=$INFERENCE_BACKEND)"
fi

cat <<BANNER

╔══════════════════════════════════════════╗
║     Tekshot AI — Universal Setup         ║
╠══════════════════════════════════════════╣
║  Device : ${PI_ID}
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

write_file "${BASE_DIR}/tekshot-core/.env" <<EOF
HOST=0.0.0.0
PORT=5005
APP_TYPE=${APP_TYPE}
ENABLE_AI_FACE=${ENABLE_AI_FACE}
UPDATE_TOKEN=${UPDATE_TOKEN}
WATCHTOWER_URL=http://localhost:8080
WATCHTOWER_TOKEN=${WATCHTOWER_TOKEN}
EOF

write_file "${BASE_DIR}/tekshot-core/config.yaml" <<'EOF'
timelapse:
  interval_seconds: 48
  cycle_hours: 24
  start_hour: 1
EOF

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
log "Phase 5: Generating docker-compose.yml for ${TARGET_OS^^}"

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
      - INFERENCE_BACKEND=tensorrt
      - TRT_PRECISION=fp16
      - GO2RTC_URL=http://go2rtc:1984
      - MEDIAMTX_URL=http://mediamtx:9997
      - MEDIAMTX_RTSP_HOST=go2rtc
    volumes:
      - ./tekshot-core/timelapse:/app/timelapse
      - ./tekshot-core/temp:/app/temp
      - ./tekshot-core/logs:/app/logs
      - ./tekshot-core/config.yaml:/app/config.yaml
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
      test: ["CMD", "curl", "-f", "http://localhost:5005/"]
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
      - TZ=Asia/Ho_Chi_Minh
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "127.0.0.1:8080:8080"
EOF

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
      - ./tekshot-core/config.yaml:/app/config.yaml
      - ./tekshot-core/data:/app/data
      - /usr/lib/python3/dist-packages/hailo_platform:/usr/lib/python3/dist-packages/hailo_platform:ro
      - /usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:ro
      - /usr/lib/libhailort.so:/usr/lib/libhailort.so:ro
      - /usr/lib/libhailort.so.4.23.0:/usr/lib/libhailort.so.4.23.0:ro
    depends_on:
      - go2rtc
      - mediamtx
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5005/"]
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
      - TZ=Asia/Ho_Chi_Minh
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "127.0.0.1:8080:8080"
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
