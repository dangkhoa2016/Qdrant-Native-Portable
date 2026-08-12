# Xóa sạch và cài lại chỉ dành cho test

> 🌐 Language / Ngôn ngữ: [English](RESET-REINSTALL.md) | **Tiếng Việt**

Các lệnh vòng đời thông thường đều không destructive. `setup`, `start`, `stop`, `restart` và `cleanup` giữ nguyên database storage và snapshot.

Chỉ dùng các lệnh bên dưới khi chủ động cần một **runtime test/benchmark hoàn toàn sạch**.

## Xóa sạch và cài lại

```bash
bash qdrant.sh reinstall-test
```

Lệnh sẽ stop ingress/process của project, xóa toàn bộ `BASE_DIR` do project quản lý rồi chạy setup từ đầu. Nó xóa:

- Qdrant binary và archive đã tải;
- live storage và collection;
- snapshot và recovery backup;
- log, PID, temp/cache;
- benchmark result;
- API-key/JWT runtime files;
- generated config và runtime settings;
- cloudflared binary nằm trong runtime của project.

Lệnh **không** gỡ apt package và không xóa system service user tùy chọn.

## Chỉ reset, chưa cài lại

```bash
bash qdrant.sh reset-test --yes
```

## Chạy tự động

`--yes` bỏ bước nhập xác nhận tương tác nhưng các guardrail đường dẫn vẫn chạy:

```bash
bash qdrant.sh reinstall-test --yes
```

## Fresh target, thư mục rỗng và runtime cũ

Nếu `BASE_DIR` chưa tồn tại, hoặc tồn tại nhưng hoàn toàn rỗng, lệnh xem đây là fresh target. Không có dữ liệu runtime cũ cần cấp quyền xóa, vì vậy không cần instance marker và cũng không cần `--force-unmanaged`. Điều này đặc biệt quan trọng với `CLEAN_REINSTALL=1` trên một session Colab/Kaggle mới.

Install mới có `$BASE_DIR/.qdrant-native-portable-instance`. Với runtime cũ non-empty chưa có marker, sau khi kiểm tra kỹ `BASE_DIR` đúng là runtime có thể xóa, dùng:

```bash
bash qdrant.sh reinstall-test --force-unmanaged --yes
```

`--force-unmanaged` chỉ bỏ yêu cầu marker; nó không vô hiệu hóa kiểm tra đường dẫn an toàn.

## Purge toàn bộ dữ liệu project trên các đường dẫn khác nhau theo platform

Với máy benchmark disposable, bạn không cần nhớ thủ công runtime/export nằm ở đâu. Dùng:

```bash
bash qdrant.sh purge-all-test --yes
```

Helper tự phát hiện `BASE_DIR` hiện tại, pointer `.qdrant-base`, runtime mặc định của platform, managed runtime dưới các root hẹp của platform, và benchmark export root đang cấu hình/mặc định. Tất cả candidate được preflight **trước khi bất kỳ dữ liệu nào bị xóa**. Chỉ cần một thư mục non-empty không nhận diện được là runtime Qdrant Native Portable thì toàn bộ purge sẽ dừng.

Lệnh xóa runtime Qdrant (binary, storage, snapshot, log, credential, config, download, temp/cache, token, recovery backup), benchmark artifact bên ngoài, runtime pointer local, benchmark ZIP generated và Python cache. Nó không xóa source repository, package hệ điều hành hay service user tùy chọn.

Xem trước toàn bộ kế hoạch mà không thay đổi gì:

```bash
bash qdrant.sh purge-all-test --dry-run
```

Xóa sạch rồi cài lại ngay:

```bash
bash qdrant.sh purge-all-test --yes --reinstall
```

Nếu có runtime legacy/custom đặc biệt mà môi trường hiện tại không thể tự phát hiện, thêm candidate một cách tường minh:

```bash
bash qdrant.sh purge-all-test --yes --base-dir /absolute/path/to/runtime
```

Hoặc dùng biến môi trường colon-separated cho automation:

```bash
QDRANT_PURGE_EXTRA_BASE_DIRS=/path/a:/path/b \
  bash qdrant.sh purge-all-test --yes
```

### Một lệnh tạo benchmark baseline sạch

Trên các máy validation ephemeral, lệnh destructive được khuyến nghị là:

```bash
bash run-fresh-qdrant-benchmarks.sh --yes
```

Entrypoint này yêu cầu canonical source integrity phải `CLEAN` trước, sau đó mới purge toàn bộ dữ liệu project và cuối cùng mới chạy smart benchmark wrapper. Thứ tự này tránh trường hợp source DIRTY nhưng runtime hữu ích đã bị xóa trước khi benchmark bị từ chối.

## A/B profile

Biến môi trường explicit vẫn được giữ qua lần reset và dùng cho setup mới:

```bash
QDRANT_PROFILE=balanced-lite bash qdrant.sh reinstall-test --yes
```

Nếu không truyền profile explicit, `runtime.env` cũ đã bị xóa nên platform/hardware auto-detection được tính lại hoàn toàn.

## Dry run

```bash
bash qdrant.sh reinstall-test --dry-run
```

Helper destructive từ chối các đường dẫn rộng/nguy hiểm như `/`, `$HOME`, `/content`, `/kaggle/working`, `/workspaces`, `/tmp`, `/etc`, `/usr` và chính source repository.
