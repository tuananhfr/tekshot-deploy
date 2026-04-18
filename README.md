# Tekshot AI — Universal Provisioning Script

Script `setup.sh` là công cụ tự động hóa quá trình cấu hình và sinh file cài đặt (`docker-compose.yml`, `.env`, `frpc.toml`, cấu hình `mediamtx`, v.v.) cho hệ thống Tekshot Core trên các thiết bị Edge (như Raspberry Pi hoặc máy tính Windows).

Script này sẽ tự động tạo một thư mục làm việc mới tên là **`tekshot-run`** tại đường dẫn hiện tại và cấu hình mọi thứ vào đó.

## Yêu cầu trước khi chạy
- **Linux (Raspberry Pi):** Máy đã cài đặt `curl` và kết nối mạng (script có khả năng tự tải Docker nếu chưa có). Khuyến nghị cài sẵn Docker.
- **Windows:** Bắt buộc phải cài sẵn **Docker Desktop** (hoặc môi trường chạy Docker tương đương) từ trước.

---

## Cách sử dụng (Usage)

Cú pháp:
```bash
./setup.sh [TARGET_OS] <DEVICE_ID> <TYPE>
```

### Tham số
1. **`TARGET_OS` (Tùy chọn)**: 
   - `pi` (Dành cho Raspberry Pi - ARM64 Native)
   - `win` (Dành cho Windows máy chủ - AMD64 TensorRT qua Docker Desktop)
   - *Nếu bỏ trống, hệ thống mặc định coi là `pi`*
2. **`DEVICE_ID` (Bắt buộc)**: Mã định danh thiết bị độc nhất dùng cho tạo domain FRP và quản lý tên camera.
   - Bắt buộc phải bắt đầu bằng chữ `pi` (VD: `pi4`, `pi-store2`) đối với hệ thống Pi.
   - Bắt buộc bắt đầu bằng chữ `win` (VD: `win-store1`) đối với hệ thống Windows.
3. **`TYPE` (Tùy chọn)**: Quy định chế độ chạy. Mặc định là `all`.
   - `all`: Chạy full cấu hình và mở module nhận diện khuôn mặt (Face AI).
   - `timelapse`: Chỉ chạy chế độ Timelapse.

---

## Các ví dụ điển hình

### 1. Triển khai lên Raspberry Pi (Mặc định)
```bash
# Setup Pi có tên là 'pi4', chạy full tất cả module
bash setup.sh pi4 all

# Setup Pi có tên là 'pi-store1', chỉ chạy module timelapse
bash setup.sh pi-store1 timelapse

# Khai báo rõ ràng hệ điều hành là 'pi' (Cách mới)
bash setup.sh pi pi-store1 all
```

### 2. Triển khai lên máy tính Windows có GPU
Script sẽ tự động dò tìm GPU qua `nvidia-smi` để kéo phiên bản Docker Image phù hợp (`tensorrt10`, `tensorrt` hoặc `onnx` nếu không có GPU).

```bash
# Setup hệ thống Windows có thiết bị định danh thẻ 'win-hanoi', chạy full module
bash setup.sh win win-hanoi all
```

---

## 4 Bước triển khai thực tế

**Bước 1:** Clone repo chứa script setup về máy đích (hoặc tải trực tiếp file `setup.sh` về máy).
```bash
git clone https://github.com/tuananhfr/tekshot-deploy.git
cd tekshot-deploy
```

**Bước 2:** Cấp quyền thực thi và chạy lệnh Setup
```bash
chmod +x setup.sh

# Sinh cấu hình (ví dụ cho Pi)
./setup.sh pi99 all
```

**Bước 3:** Đăng nhập vào Github Container Registry
Phiên bản hiện tại sử dụng Docker Image Private từ Github. Bạn phải mượn PAT (Personal Access Token) từ admin và chạy:
```bash
docker login ghcr.io -u tuananhfr
# Password: <Nhập PAT token vào đây>
```

**Bước 4:** Khởi động hệ thống
```bash
# Chuyển vào thư mục được script sinh ra
cd tekshot-run

# Chạy hệ thống dưới background
docker compose up -d
```

Đến bước này, hệ thống sẽ tự động liên kết mọi container (API, AI Pipeline, Camera stream, FRP Tunnel...) để thiết bị sãn sàng phục vụ.
