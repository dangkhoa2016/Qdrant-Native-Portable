# Single-node production

> 🌐 Language / Ngôn ngữ: [English](PRODUCTION.md) | **Tiếng Việt**

Nhánh production hiện tại cố ý chỉ hỗ trợ **single-node**. Nó bổ sung policy/lifecycle an toàn hơn nhưng giữ nguyên các mặc định development đã được chứng minh.

## Native production

```bash
export QDRANT_API_KEY='replace-me'
export QDRANT_READ_ONLY_API_KEY='replace-me-too'
export QNP_ENV=production
export QNP_RUNTIME=native
export QNP_TOPOLOGY=single
export PUBLIC_MODE=none
bash qdrant.sh production-check
bash qdrant.sh prepare
exec bash qdrant.sh serve
```

`prepare` cài đặt/cấu hình nhưng không start Qdrant. `serve` dùng foreground `exec`, phù hợp với VM/container supervisor. Production mặc định không tạo demo collection và không tự public bằng Quick Tunnel. Với `QNP_SECRET_POLICY=require-env`, API key phải do caller inject cho từng lệnh production và không được persist vào `secrets.env`.

Quick Tunnel chỉ là demo ingress; production phải đặt đồng thời `PUBLIC_MODE=cloudflare-quick` và `QNP_ALLOW_DEMO_TUNNEL=1`.

Để native deployment có live data bền vững, thư mục Qdrant phải nằm trên storage có block-level access và filesystem tương thích POSIX. Không dùng NFS, S3/object storage, FUSE cloud drive hoặc provider mount chưa chứng minh semantics phù hợp làm live database path.

## Docker production

```bash
export QDRANT_API_KEY='replace-me'
export QDRANT_READ_ONLY_API_KEY='replace-me-too'
docker compose -f docker/docker-compose.yml up --build
```

Reference image pin official Qdrant `v1.18.3-unprivileged`, chạy UID/GID 1000. Compose reference dùng Docker named volume tại `/qdrant/storage`, root filesystem read-only, drop Linux capabilities và chỉ bind host port trên loopback.

Healthcheck dùng `/readyz` và không đưa API key vào command line. Docker named volume vẫn phụ thuộc filesystem/storage driver thật của host, vì vậy cần xác nhận nó đáp ứng yêu cầu block/POSIX của Qdrant.

### Các storage mode của Docker

`QNP_STORAGE_MODE`:

```text
local                       live storage local/block-backed; mặc định
snapshot-persist            live storage local + full snapshot trên persistent mount
direct-mount-experimental   dùng provider mount trực tiếp làm live storage; chỉ để thử nghiệm
```

Với `snapshot-persist`, `QNP_PERSIST_PATH` phải là một đường dẫn writable tách biệt. Full-storage snapshot được tạo trong vùng local `/qdrant/snapshots` tách biệt, copy sang persistent path kèm SHA256 và có thể tự restore khi container mới khởi động bằng `--storage-snapshot`. Auto-restore không bao giờ ghi đè một live data directory đang có dữ liệu.

Việc chọn snapshot restore theo nguyên tắc fail-closed: snapshot preferred/mới nhất bị corrupt sẽ bị bỏ qua để fallback sang snapshot cũ hơn mới nhất còn hợp lệ theo checksum; nếu persistent snapshot có tồn tại nhưng không file nào verify được, QNP từ chối khởi động một Qdrant rỗng. Với Qdrant 1.18.3, `snapshot-persist` chủ động không ép `storage.temp_path` của Qdrant để full-storage recovery tự cấp các recovery directory riêng và tránh xung đột khi unpack archive.

Các biến hữu ích:

```text
QNP_PERSIST_PATH=/qdrant-persist
QNP_REQUIRE_PERSIST_MOUNT=1
QNP_AUTO_RESTORE=1
QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=900
QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=1
QNP_SHUTDOWN_SNAPSHOT_TIMEOUT_SECONDS=20
QNP_SNAPSHOT_RETENTION=3
```

Periodic snapshot là cơ chế chính để chống mất dữ liệu khi platform dừng đột ngột. Snapshot lúc shutdown chỉ là best-effort.

`direct-mount-experimental` bắt buộc double opt-in:

```text
QNP_ALLOW_UNSUPPORTED_STORAGE=1
```

QNP không vô hiệu hóa filesystem safety check của Qdrant.

## Theo provider

| Target | Runtime | Persistence trong revision này | Mục tiêu |
|---|---|---|---|
| Generic Linux/VPS | Native | Live DB trên local/block storage phù hợp | Production single-node |
| Generic Docker host | Docker | Live DB trên Docker volume phù hợp | Production single-node |
| Kaggle | Native | Phụ thuộc Session Persistence | Production-demo / production-light |
| Colab | Native | Ephemeral trừ khi restore/export riêng | Production-demo |
| GitHub Codespaces | Native | Phụ thuộc lifecycle workspace | Production-demo / integration |
| Hugging Face Spaces | Docker | Live DB cục bộ + full snapshot trên Bucket | **Real-provider validated** |
| Modal.com | Docker | Live DB cục bộ + full snapshot trên Modal Volume | **Real-provider validated** |
| Beam.cloud | Docker | Live DB cục bộ + full snapshot trên Beam Volume | **Real-provider validated** |

### Hugging Face Spaces

Attach một read-write Storage Bucket vào:

```text
/qdrant-persist
```

và đặt:

```text
QNP_STORAGE_MODE=snapshot-persist
QNP_PERSIST_PATH=/qdrant-persist
QNP_REQUIRE_PERSIST_MOUNT=1
QNP_AUTO_RESTORE=1
QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=900
QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=1
QNP_SHUTDOWN_SNAPSHOT_TIMEOUT_SECONDS=20
QNP_SNAPSHOT_RETENTION=3
```

Live database nằm ở `/qdrant/storage` trên local Space disk. Full-storage snapshot hoàn tất được copy sang `/qdrant-persist/full`. Khi startup, snapshot mới nhất hợp lệ (hoặc snapshot được `LATEST` trỏ tới) được verify SHA256, copy về local và truyền cho Qdrant bằng `--storage-snapshot`.

Thiết kế này dùng Bucket cho file archive bền vững, không dùng nó cho segment/index đang sống. Hugging Face mô tả Storage Bucket là S3-like object storage được expose qua volume mount, trong khi live Qdrant database cần block/POSIX storage.

Chỉ để nghiên cứu, có thể bật `QNP_STORAGE_MODE=direct-mount-experimental` cùng `QNP_ALLOW_UNSUPPORTED_STORAGE=1`. QNP không tuyên bố mode này an toàn/supported và không bypass filesystem compatibility check của Qdrant.

### Modal.com

Adapter Modal dùng **Modal Volume chỉ làm tầng lưu bền vững cho completed snapshot**. Live Qdrant database vẫn nằm trên filesystem local của container tại `/qdrant/storage`; Volume `qnp-qdrant-persist` được mount tại `/qdrant-persist` và QNP chạy bằng `snapshot-persist`. Thiết kế này giữ đúng storage boundary đã được kiểm chứng ở adapter Hugging Face thay vì coi distributed Volume là live block storage.

Adapter dùng primitive `@app.server` hiện tại của Modal, xóa Docker image ENTRYPOINT để Python runtime của Modal khởi động được, rồi chạy `/qdrant/qnp-entrypoint.sh` trong `@modal.enter`. Topology được fail-closed ở một writer bằng `max_containers=1`. `min_containers=0` cùng scaledown window 15 phút cho phép scale-to-zero; cold start sẽ restore full snapshot mới nhất vượt qua checksum khi local live storage đang rỗng.

Modal Volume được provider expose như filesystem nhưng không bắt buộc phải xuất hiện như một Linux mountpoint truyền thống trong `/proc/self/mountinfo`. Vì vậy trước khi launch QNP, adapter ghi một probe duy nhất vào `/qdrant-persist`, gọi `persist_volume.commit()`, rồi đọc lại đúng bytes đã commit qua Modal Volume API. Chỉ sau khi durable round trip này PASS thì QNP child mới bỏ qua generic Linux mount-table check. Nếu write, commit, read-back, content match hoặc cleanup commit lỗi, adapter vẫn fail-closed và Qdrant không được khởi động.

Persistence policy mặc định:

```text
QNP_STORAGE_MODE=snapshot-persist
QNP_PERSIST_PATH=/qdrant-persist
QNP_REQUIRE_PERSIST_MOUNT=1
QNP_AUTO_RESTORE=1
QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=600
QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0
QNP_SNAPSHOT_RETENTION=3
```

Periodic snapshot là durability boundary chính thức của Modal. Adapter dùng cadence 600 giây với scaledown window 900 giây, tạo khoảng cách danh nghĩa 300 giây; đồng thời enforce safety margin tối thiểu 180 giây để race hai timer bằng nhau không thể quay lại. Modal Server gửi tín hiệu dừng tới các process đang chạy đồng thời với `@modal.exit()`, nên adapter chủ động đặt `QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0` thay vì hứa một thứ tự shutdown không thể bảo đảm. Exit hook vẫn thực hiện cleanup child và `persist_volume.commit()` cuối cho các periodic snapshot đã hoàn tất. Real-provider validation đã chứng minh auth 401/200/200/403, periodic snapshot trên dữ liệu thật, scale-down/recreation, newest-valid auto-restore, Qdrant collection recovery và exact sentinel sống sót. Lần real-provider validation cuối ngày 2026-08-18 còn chứng minh chuỗi fresh-write mạnh hơn: sentinel mới ghi đã sống sót qua một lần scale-down/recreation tiếp theo sau hai full snapshot định kỳ hoàn tất; exit hook hoàn tất final Volume commit, container kế tiếp restore snapshot hợp lệ mới nhất, và exact point/payload của sentinel được recover. RPO của thiết kế vì vậy bị chặn bởi cadence periodic (danh nghĩa <=600 giây), không phụ thuộc shutdown snapshot.

Để thu evidence, hãy export `QDRANT_URL` của deployment và `QDRANT_READ_ONLY_API_KEY`, rồi chạy `examples/production/collect-modal-validation-result.sh`. Mặc định script ghi ra thư mục sibling `qnp-modal-results/` nằm ngoài source tree để generated evidence không làm source-integrity thành DIRTY. Ngoài Modal app log, Volume listing, source-integrity và metadata, collector còn ghi response read-only của `/collections`, collection sentinel và point sentinel. Trạng thái từng provider/API probe được ghi vào `collection-status.txt`, nên một nguồn evidence tạm thời không truy cập được sẽ không làm mất các evidence còn lại. Collector từ chối tạo ZIP nếu bất kỳ file thu thập nào chứa đúng giá trị admin hoặc read-only API key hiện tại.

### Beam.cloud

Adapter Beam hiện có một **đường snapshot-persistence đã real-provider validated**. Nó attach Beam Volume `qnp-qdrant-persist` tại `/qdrant-persist` để giữ các full snapshot đã hoàn tất và có checksum, trong khi live Qdrant database vẫn nằm trên `/qdrant/storage` local của container. Volume chủ động **không** được dùng làm live database storage, vì adapter không giả định distributed-volume semantics tương đương block/POSIX storage cần thiết cho live files của Qdrant.

Môi trường staging dùng:

```text
QNP_STORAGE_MODE=snapshot-persist
QNP_PERSIST_PATH=/qdrant-persist
QNP_REQUIRE_PERSIST_MOUNT=1
QNP_AUTO_RESTORE=1
QNP_AUTO_SNAPSHOT_INTERVAL_SECONDS=600
QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0
QNP_SNAPSHOT_RETENTION=3
QNP_READY_TIMEOUT_SECONDS=180
```

`deploy/beam/entrypoint.sh` chạy provider preflight fail-closed trước khi QNP start: path attach phải tồn tại và writable, một probe riêng được ghi + fsync, đọc lại exact bytes, rồi phải xóa được probe. Chỉ sau đó wrapper mới `exec /qdrant/qnp-entrypoint.sh`. Generic QNP mounted-volume guard vẫn được bật trong provider path này; nếu test Beam thật chứng minh representation của Beam mount không tương thích với generic check, adapter phải có provider-specific proof trước khi chỉ tắt phần check không tương thích.

Phase A chủ động dùng `keep_warm_seconds=-1`. Sau khi ghi sentinel mới, operator chờ full snapshot định kỳ và checksum xuất hiện, rồi dừng container thật bằng `beam container stop <CONTAINER-ID>`. Request sau đó sẽ dùng/start container mới và `examples/production/beam-sentinel.sh verify-readonly` kiểm tra exact point cũ chỉ bằng read-only API key. Beam ghi rõ file mới ghi vào distributed Volume có thể mất tới 60 giây mới visible với container khác, nên verifier Beam dùng bounded polling thay vì coi lần đọc cold-start đầu tiên là kết luận cuối.

Đường Beam real-provider đã hoàn tất xác thực cho mô hình snapshot-persistence single-node đã tài liệu hóa: normal recreation/restore, newest-valid selection, corrupt-newest fallback, all-corrupt fail-closed, retention, recovery và secret-safe evidence collection đều đã được kiểm tra trên Beam.cloud. `QNP_AUTO_SNAPSHOT_ON_SHUTDOWN=0` vẫn là chủ ý; periodic snapshot xác định durability boundary thay vì claim shutdown ordering chưa được chứng minh.

Workflow cho operator nằm trong `examples/production/production-beam.cloud-example.sh`. `examples/production/collect-beam-validation-result.sh` đóng gói Beam deployment/container/Volume inventory, optional deployment/container log capture, Qdrant authorization status, response read-only của collection/sentinel, source-integrity và phase metadata. Collector không dump raw container environment và từ chối tạo ZIP nếu file evidence nào chứa đúng giá trị admin hoặc read-only Qdrant API key hiện tại.

Không bật cluster/peer networking. Nhiều Qdrant writer chạy đồng thời vẫn chủ động nằm ngoài topology single-node được hỗ trợ.
