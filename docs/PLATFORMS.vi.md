# Platform và Deployment Mode

> 🌐 Language / Ngôn ngữ: [English](PLATFORMS.md) | **Tiếng Việt**

Project tách bốn quyết định riêng: **phát hiện platform**, **process isolation**, **deployment topology** và **public access**. Mọi lựa chọn tự động đều có thể override bằng environment variable.

## Auto-detection

Chạy:

```bash
bash qdrant.sh system-info
```

Detector nhận biết Google Colab, Kaggle, GitHub Codespaces, các Linux VM kiểu CodeSandbox và Linux thông thường.

| Biến | Giá trị |
|---|---|
| `PROCESS_MODE` | `auto`, `current-user`, `service-user` |
| `DEPLOYMENT_MODE` | `auto`, `minimal`, `proxy` |
| `PUBLIC_MODE` | `auto`, `cloudflare-quick`, `platform`, `none` |
| `QDRANT_PROFILE` | `auto`, `low-memory`, `balanced-lite`, `balanced-memory`, `balanced`, `performance` |

Giá trị environment do người dùng chỉ định được ưu tiên hơn runtime state đã lưu và auto-detection. Nếu một hosted VM không cung cấp marker ổn định, có thể ép platform rõ ràng:

```bash
QDRANT_PLATFORM=codesandbox bash qdrant.sh system-info
QDRANT_PLATFORM=generic-linux bash qdrant.sh setup
```

Benchmark JSON ghi lại platform cuối cùng, profile, process mode và deployment mode để có thể so sánh kết quả mà không cần đoán cấu hình runtime. Auto profile dùng effective memory: giá trị nhỏ hơn giữa RAM host nhìn thấy và finite cgroup memory limit. `system-info` hiển thị cả hai.

## Rootless/current-user mode

Khuyên dùng cho GitHub Codespaces, VM kiểu CodeSandbox và Linux account bị giới hạn quyền:

```bash
PROCESS_MODE=current-user \
DEPLOYMENT_MODE=minimal \
bash qdrant.sh setup
```

Qdrant chạy bằng user hiện tại. Toolkit không tạo system user và không ghi Nginx config. REST local thường là `127.0.0.1:6333`.

## Service-user/proxy mode

Phù hợp cho Colab hoặc môi trường root dùng để demo:

```bash
PROCESS_MODE=service-user \
DEPLOYMENT_MODE=proxy \
bash qdrant.sh setup
```

Qdrant chạy bằng non-login user riêng, Nginx cung cấp REST proxy loopback ở port `9090`. Mode này cần root.

## GitHub Codespaces

Codespace khoảng 8 GB điển hình dùng `balanced-memory`, `current-user`, `minimal`. Đây là default đã được chứng minh cho lớp RAM này; `auto` thường tự chọn tương đương.

```bash
bash qdrant.sh setup
bash qdrant.sh system-info
```

Publish forwarded Qdrant port:

```bash
bash qdrant.sh public
```

Đưa port về private:

```bash
bash qdrant.sh public-stop
```

Organization policy có thể cấm public port. Nếu publish thất bại, giữ port private hoặc dùng ingress được tổ chức cho phép.

## Google Colab và Kaggle

Khi có root, `auto` giữ topology service-user + Nginx proxy quen thuộc. Live storage nên nằm trên local runtime storage; hãy export snapshot hoàn tất sang nơi bền vững trước khi runtime ephemeral bị xóa.

## VM kiểu CodeSandbox

Các môi trường này có thể khác nhau. Baseline portable an toàn là:

```bash
PROCESS_MODE=current-user \
DEPLOYMENT_MODE=minimal \
PUBLIC_MODE=cloudflare-quick \
bash qdrant.sh setup
```

Nếu platform có authenticated port forwarding riêng thì nên ưu tiên nó thay vì thêm một public tunnel.

## Linux thông thường

Core database không bắt buộc root. `current-user + minimal` là mode ít xâm lấn nhất. Chỉ dùng `service-user + proxy` khi chủ động cần system integration và có root.

## Runtime state

Cấu hình vận hành không chứa secret được lưu tại:

```text
$BASE_DIR/runtime.env
```

Secret nằm riêng tại:

```text
$BASE_DIR/secrets.env
```

File `.qdrant-base` trong repository chỉ nhớ runtime directory đã dùng gần nhất; file bị Git ignore và không chứa credential.
