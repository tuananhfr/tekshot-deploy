# Cài Tekshot v2 trên Raspberry Pi

Hướng dẫn này dựng một Pi chạy backend **v2** bằng Docker, kéo ảnh từ GHCR.

Có hai đường vào:

- **[Phần A](#phần-a--máy-mới)** — máy trắng, chưa cài gì.
- **[Phần B](#phần-b--máy-đang-chạy-v1)** — máy đang chạy v1, cần dọn sạch trước.

Máy đang chạy v1 thì đọc **Phần B trước**, xong quay lại Phần A từ bước A2.

---

## Yêu cầu phần cứng và hệ điều hành

- Raspberry Pi 5 + Hailo-8L, `/dev/hailo0` tồn tại
- Debian 13, **Python hệ thống 3.13**
- `hailo_platform` trong `/usr/lib/python3/dist-packages`
- `/usr/lib/libhailort.so.4.23.0`
- Docker

> **Ảnh Docker KHÔNG chứa SDK Hailo.** Nó mượn của host lúc chạy qua bind mount.
> Vì vậy phiên bản phải khớp:
>
> - Binding của host là `_pyhailort.cpython-**313**-aarch64-linux-gnu.so`, còn ảnh
>   dùng `python:3.13-slim`. Lệch bản vá (3.13.5 với 3.13.15) thì không sao, nhưng
>   host chạy 3.12 hay 3.14 là bind mount không nạp được.
> - Số `4.23.0` bị ghim trong ảnh. Nâng HailoRT trên host là phải build lại base
>   image, không phải build lại app image.

Kiểm tra nhanh:

```bash
python3 -V                                    # phải là 3.13.x
ls /usr/lib/python3/dist-packages/hailo_platform
ls -l /usr/lib/libhailort.so.4.23.0 /dev/hailo0
docker --version
```

---

## Phần A — Máy mới

### A1. Đăng nhập GHCR

Các package là private. Thiếu bước này thì mọi lệnh pull trả về `denied`, và thông
báo đó không nói gì về nguyên nhân.

```bash
docker login ghcr.io -u tuananhfr
# Password: dán PAT có quyền read:packages
```

Kiểm tra — lệnh này không tải gì, chỉ hỏi registry:

```bash
docker manifest inspect ghcr.io/tuananhfr/tekshot-ai-v2:stable > /dev/null && echo OK
```

> **Đọc kỹ lỗi trước khi kết luận.**
>
> - `denied` — registry trả lời: token sai hoặc hết hạn.
> - `i/o timeout` tới `20.205.243.164` — **lỗi mạng, không phải quyền**. GHCR chập
>   chờn thật; thử lại 3–5 lần rồi mới kết luận.
>
> Cách phân biệt token chết với thiếu quyền trên package: thử pull một ảnh **cũ**
> mà máy này từng kéo được. Nếu ảnh đó *cũng* `denied` thì là token.

### A2. Lấy script provisioning

Mã nguồn backend không cần có mặt trên thiết bị. Repo này chỉ có `setup.sh`,
`README.md` và file bạn đang đọc.

```bash
cd ~/Desktop
git clone https://github.com/tuananhfr/tekshot-deploy.git
cd tekshot-deploy
```

Nếu đã clone từ trước:

```bash
cd ~/Desktop/tekshot-deploy && git pull
```

### A3. Sinh cấu hình cho thiết bị

```bash
bash setup.sh --v2 pi pi4 all
```

| Tham số | Ý nghĩa |
| --- | --- |
| `--v2` | dùng ảnh `tekshot-ai-v2:stable`. **Vẫn phải truyền mỗi lần** — bỏ đi là rơi vào nhánh v1 của generator, trỏ tới `tekshot-ai:stable`, một ảnh không còn ai build kể từ 2026-08-13. |
| `pi` | hệ điều hành đích (`pi` hoặc `win`) |
| `pi4` | **mã thiết bị** — thành `subdomain` của tunnel FRP và tiền tố tên camera. Mỗi máy một mã riêng. |
| `all` | thành `APP_TYPE`. `timelapse` thì chỉ chạy timelapse. |

Script sinh ra thư mục `tekshot-run/` gồm `docker-compose.yml`, `.env`,
`frpc.toml`, `go2rtc.yaml`, `mediamtx.yml`, `nginx.conf` — đã khớp sẵn với nhau.

> **Script ghi vào `$PWD/tekshot-run` và ĐÈ LÊN bản cũ nếu đã có.** Máy mới thì vô
> hại. Máy đã có một stack đang chạy thì `cd` sang thư mục khác trước khi chạy, nếu
> không compose và cấu hình hiện tại bị thay mất.

**Đổi FRP server** không cần sửa script:

```bash
FRP_SERVER=203.0.113.9 FRP_PORT=7100 FRP_TOKEN=s3cr3t \
  bash setup.sh --v2 pi pi4 all
```

Mặc định v2 trỏ vào `camera.tekshot.vn:7000`. Token mặc định `123456` nằm trong một
repo public nên coi như đã lộ — đổi server là dịp gọn nhất để đổi luôn token.

### A4. Khởi động

```bash
cd tekshot-run
docker compose up -d
docker compose ps
```

Sáu container: `tekshot-core`, `go2rtc`, `mediamtx`, `frpc` (tunnel), `nginx-router`
(cổng vào 8090), `watchtower`.

```bash
curl -s http://127.0.0.1:5005/api/v1/system/health
```

Mong đợi `"status":"ok"`, `"db":"ok"`, và **`"pipeline":"stopped"`**.

> **`stopped` ở đây là ĐÚNG.** Database mới tinh chưa có camera nào, nên pipeline
> không khởi động và **NPU chưa hề bị chạm tới**. Health xanh ở bước này không
> chứng minh được gì về Hailo — bước A5 mới chứng minh.

### A5. Thêm camera — bước này mới thực sự chạy AI

```bash
curl -X POST http://127.0.0.1:5005/api/v1/cameras \
  -H 'Content-Type: application/json' \
  -d '{"id":"camera_1","name":"cong-truoc",
       "url":"rtsp://user:pass@192.168.1.50:554/stream1",
       "sub_url":"rtsp://user:pass@192.168.1.50:554/stream2",
       "ai_enabled":true,"record_enabled":true}'
```

> **`id` là bắt buộc**, dạng `camera_1` … `camera_4`. Schema hiển thị nó là tuỳ
> chọn, nhưng bỏ trống thì API trả `Invalid camera id ''`.

Handler này ghi DB, đẩy cả hai luồng sang go2rtc và nạp lại pipeline trong một lệnh.
Sau này đổi IP camera cũng bằng `PUT /cameras/{id}` — **không bao giờ sửa tay
`go2rtc.yaml`**, vì lần đồng bộ kế tiếp sẽ ghi đè lên.

### A6. Xác nhận Hailo nạp model thật

```bash
curl -s http://127.0.0.1:5005/api/v1/system/health     # pipeline: running, face: running
docker logs tekshot-core --tail 80 | grep -i hailo
```

Phải thấy HailoRT nạp `yolov8n.hef`, `scrfd_2.5g.hef` và `arcface_gender_age.hef`.
Trên Pi 5 + Hailo-8L, `yolov8n` chạy khoảng 30 fps.

**Ba trạng thái `stopped` lành tính, không phải lỗi:**

| | |
| --- | --- |
| `lpr: stopped` | chưa ai compile HEF cho biển số — v1 chỉ có bản `.onnx`. Trên Pi nó sẽ **luôn** như vậy. |
| `occupancy: stopped` | chưa camera nào bật đếm người |
| `face: library-only` | thiếu model khuôn mặt; API thư viện vẫn chạy, chỉ không nhận diện |

### A7. Truy cập

| | |
| --- | --- |
| Backend trực tiếp | `http://<ip>:5005` |
| Qua nginx-router | `http://<ip>:8090`, kèm `/go2rtc/` |
| Từ xa qua FRP | `<mã-thiết-bị>` và `go2rtc-<mã-thiết-bị>` làm subdomain trên `camera.tekshot.vn` |

---

## Phần B — Máy đang chạy v1

Làm đúng thứ tự: **sao lưu → dừng → xoá → cài lại**. Đảo thứ tự là mất dữ liệu.

### B1. Xem máy đang có gì

```bash
# Tiến trình chạy tay (nếu máy từng dùng bản bare-metal)
ps -eo pid,cmd --no-headers | grep -E "[m]ain\.py|[g]o2rtc|[m]ediamtx"

# Container
docker ps -a

# Dung lượng
du -sh ~/tekshot-ai ~/v2-media ~/Desktop/tekshot-deploy/tekshot-run 2>/dev/null
df -h /
```

### B2. Sao lưu thứ không tái tạo được

Mã nguồn thì xoá thoải mái — nó nằm trong git trên máy dev. Vấn đề là **dữ liệu
runtime nằm chung thư mục với mã nguồn**, và nó chưa bao giờ được đồng bộ đi đâu.

| Thứ cần cứu | Vì sao |
| --- | --- |
| `temp/tekshot.db` | camera kèm URL/mật khẩu, session, evidence, chấm công |
| `data/faces/` | ảnh mẫu + embedding của người đã train |
| `data/snapshots/` | ảnh evidence. Bỏ nó thì các dòng evidence trong DB trỏ vào file không còn |
| `~/v2-media/go2rtc.yaml` | URL các stream camera; go2rtc tự ghi đè file này nên đây là bản duy nhất |
| `.env` | cấu hình riêng của máy |

Chép **ra khỏi Pi**, để trên Pi thì một lệnh xoá nhầm là mất cả bản sao. Chạy từ máy
khác:

```bash
B=~/pi-backup-$(date +%Y%m%d)
mkdir -p "$B"
scp     tekshot@<pi-ip>:'~/tekshot-ai/tekshot-core/temp/tekshot.db'  "$B/"
scp -r  tekshot@<pi-ip>:'~/tekshot-ai/tekshot-core/data/faces'       "$B/"
scp -r  tekshot@<pi-ip>:'~/tekshot-ai/tekshot-core/data/snapshots'   "$B/"
scp     tekshot@<pi-ip>:'~/v2-media/go2rtc.yaml'                     "$B/"
scp     tekshot@<pi-ip>:'~/tekshot-ai/tekshot-core/.env'             "$B/env-pi.txt"
```

Kiểm tra DB chép về còn đọc được:

```bash
python3 -c "
import sqlite3; c=sqlite3.connect('$B/tekshot.db')
print('integrity:', c.execute('PRAGMA integrity_check').fetchone()[0])
print('cameras:', c.execute('SELECT COUNT(*) FROM cameras').fetchone()[0])
"
```

Recording (thường hàng chục GB) là footage thật — tự quyết định có cần không.

### B3. Dừng mọi thứ đang chạy

**Container:**

```bash
cd ~/Desktop/tekshot-deploy/tekshot-run && docker compose down
```

**Tiến trình chạy tay** (nếu máy từng dùng bản bare-metal). Thứ tự quan trọng:

```bash
pkill -f "[m]ain\.py"

# Đợi tới khi nó thoát HẲN
for i in $(seq 1 30); do
  n=$(ps -eo cmd --no-headers | grep -cx "\.venv/bin/python main\.py" || true)
  echo "poll $i: main.py=$n"
  [ "$n" -eq 0 ] && break
  sleep 3
done

# Treo quá lâu thì ép
pkill -9 -f "[m]ain\.py"

pkill -9 -x go2rtc
pkill -9 -x mediamtx
```

> **Vòng đợi không phải cẩn thận thừa.** Teardown chỉ nhả VDevice của Hailo *sau
> khi* dọn xong model, và graceful shutdown có thể treo vài phút — API ngừng trả
> lời, cổng 5005 đã nhả, nhưng tiến trình vẫn sống và vẫn giữ NPU. Khởi động cái mới
> trúng cửa sổ đó sẽ chết với `HAILO_OUT_OF_PHYSICAL_DEVICES(74)` ngay HEF đầu tiên,
> nhìn y như lỗi model.
>
> **Đếm bằng `ps -eo cmd | grep -cx`, đừng dùng `pgrep -f "python main.py"`** —
> pattern đó khớp luôn cái shell đang chạy phép kiểm tra, nên nó báo còn sống mãi
> mãi, và `pkill` cùng pattern sẽ giết chính phiên ssh của bạn.

Xác nhận cổng đã nhả:

```bash
ss -ltn | grep -E ":1984|:8554|:8556|:9997|:5005" || echo "tat ca da nha"
```

### B4. Xoá

```bash
rm -rf ~/tekshot-ai
rm -rf ~/v2-media
rm -rf ~/Desktop/tekshot-deploy/tekshot-run
```

> **Recording sẽ báo `Permission denied`.** Chúng do container MediaMTX chạy bằng
> root ghi ra, nên user thường không xoá được, mà `sudo` trên Pi lại cần mật khẩu.
> Mượn docker — daemon chạy bằng root. Mount thư mục **cha** rồi xoá đúng một thư
> mục có tên, đừng mount thẳng thư mục đích:
>
> ```bash
> docker run --rm -v /home/tekshot/Desktop/tekshot-deploy:/target \
>   alpine rm -rf /target/tekshot-run
> ```

Dọn container và ảnh cũ:

```bash
docker rm -f tekshot-core go2rtc mediamtx frpc nginx-router watchtower 2>/dev/null
docker image rm -f ghcr.io/tuananhfr/tekshot-ai:stable
docker image ls          # xem còn ảnh nào của v1 không rồi xoá tiếp
docker image prune -f
```

Ảnh MediaMTX do compose tự build mang tên theo **thư mục** chứa compose — với
`tekshot-run/` thì nó là `tekshot-run-mediamtx`. Đừng đoán tên, cứ `docker image ls`
rồi xoá cái nhìn thấy. Bốn ảnh `nginx:alpine`, `snowdreamtech/frpc`,
`alexxit/go2rtc`, `containrrr/watchtower` thì **giữ lại** — v2 dùng đúng chúng, và
chúng lấy từ Docker Hub nên không cần token.

Kiểm tra:

```bash
ls -A ~
docker ps -a
df -h /
```

### B5. Cài lại

Quay lại **[Phần A](#phần-a--máy-mới)**, bắt đầu từ **A2** (repo deploy vẫn còn,
chỉ cần `git pull`).

Muốn khôi phục dữ liệu cũ thì chép vào **sau bước A3, trước A4**:

```bash
cp    ~/pi-backup-*/tekshot.db  tekshot-run/tekshot-core/temp/
cp -r ~/pi-backup-*/faces       tekshot-run/tekshot-core/data/
cp -r ~/pi-backup-*/snapshots   tekshot-run/tekshot-core/data/
```

Có DB cũ thì camera quay lại luôn, và `sync_all` lúc khởi động sẽ tự đẩy chúng sang
go2rtc — không phải khai báo lại.

---

## Cập nhật về sau

Watchtower chạy với `POLL_INTERVAL=0` và `LABEL_ENABLE=true`, nghĩa là nó **không
bao giờ tự quét**. Cập nhật là việc làm tay:

```bash
cd ~/Desktop/tekshot-deploy/tekshot-run
docker compose pull && docker compose up -d
```

Đây là chủ ý, và kể từ 2026-08-13 nó là lớp bảo vệ **duy nhất**: ảnh được build
lại mỗi lần push vào `main` chạm `tekshot-core/app/**`, và tag giờ là `:stable`.
Trước ngày đó tag `:beta` là một lớp chặn thứ hai — không còn nữa. Máy nào bị
sinh lại stack mà mất dòng `POLL_INTERVAL=0` sẽ tự kéo bản mới trong vòng 24 giờ.

Máy cài **trước 2026-08-13** còn ghim `:beta`, một tag không ai build nữa, nên
`docker compose pull` không mang về gì cả. Sửa dòng `image:` trong
`tekshot-run/docker-compose.yml` thành `:stable` rồi pull lại.

---

## Khi có gì đó không đúng

### Pull trả về `denied`

Token hết hạn hoặc thiếu `read:packages`. Đăng nhập lại (A1). Nếu một ảnh cũ mà máy
từng kéo được *cũng* `denied` thì chắc chắn là token, không phải quyền trên package.

### `HAILO_OUT_OF_PHYSICAL_DEVICES(74)`

Một tiến trình khác đang giữ NPU — thường là bản chạy trước chưa thoát hẳn. Xem cảnh
báo ở B3. Đợi tiến trình cũ biến mất rồi mới khởi động lại.

### Health xanh nhưng camera không lên go2rtc

Kiểm tra `go2rtc.yaml` có bật `api: username/password` không. Client go2rtc của v2
chỉ nhận `base_url` và `timeout`, **không có tham số credential** — bật auth là mọi
lệnh gọi 401, `sync_all` thất bại, app ghi log rồi chạy tiếp, và health vẫn xanh
suốt. Bản `--v2` sinh ra file không auth; lỗi này chỉ xảy ra khi ai đó chép
`go2rtc.yaml` của v1 sang.

### Ảnh evidence 404, mọi người thành "unknown"

`/app/data` chưa được mount. Ảnh evidence và thư viện khuôn mặt nằm trong đó; không
mount thì chúng ở trên overlay của container và mất mỗi lần tạo lại, trong khi DB ở
`/app/temp` vẫn sống và vẫn trỏ tới file không còn tồn tại. Pipeline trông hoàn toàn
khoẻ mạnh.

### Route trả 404 dù code có

Câu hỏi đầu tiên là `APP_TYPE`, không phải routing. Máy `TIMELAPSE` không có tính
năng `events`, nên **không đăng ký cả WebSocket sự kiện lẫn WebSocket live** — máy
boot sạch, health xanh, và frontend không bao giờ nhận được frame nào.

### `import hailo_platform` lỗi trong container

Kiểm tra Python của host đúng 3.13 chưa (`python3 -V`), và hai bind mount có trong
`docker-compose.yml` không: `hailo_platform` và `libhailort.so.4.23.0`. Kiểm tra
riêng phần này mà không cần đụng cổng hay NPU:

```bash
docker run --rm --network none \
  -v /usr/lib/python3/dist-packages/hailo_platform:/usr/lib/python3/dist-packages/hailo_platform:ro \
  -v /usr/lib/libhailort.so.4.23.0:/usr/lib/libhailort.so.4.23.0:ro \
  ghcr.io/tuananhfr/tekshot-ai-v2:stable \
  python -c "import hailo_platform; print('OK')"
```

> **Không thêm `-v /usr/lib/aarch64-linux-gnu:...` vào đây.** Bản trước của
> hướng dẫn này và của `setup.sh` đều mount cả thư mục đó, và nó đè toàn bộ thư
> viện dùng chung của container bằng thư viện của host — ffmpeg trong ảnh build
> cho libavfilter 7.1.5 gặp bản 7.1.3 dựng lại của Raspberry Pi rồi chết với
> `undefined symbol: av_buffersrc_get_status`, thoát ra exit 127 nên trông y hệt
> "chưa cài ffmpeg". Toàn bộ endpoint phát lại recordings hỏng theo trong khi
> `/system/health` vẫn xanh. pyhailort không cần gì từ thư mục đó: nó chỉ link
> tới libc/libm/libpthread/librt/libstdc++/libgcc_s, container đã có sẵn.
