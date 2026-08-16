# Hướng dẫn sử dụng chi tiết

> 🌐 Language / Ngôn ngữ: [English](USAGE.md) | **Tiếng Việt**

Tài liệu này mô tả workflow portable thay vì giả định chỉ chạy trên Google Colab.

## 1. Kiểm tra trước khi cài

```bash
bash qdrant.sh doctor
bash qdrant.sh system-info
```

`doctor` kiểm tra Linux/architecture, RAM, writable storage, dependency, quyền cần cho mode đã chọn, permission của secret/config và service health nếu đã cài.

## 2. Setup tự động

```bash
# From the repository root
bash qdrant.sh setup
```

Workflow tạo/load credential, chuẩn bị dependency/runtime directory, tải Qdrant native binary, tạo config không chứa secret, start Qdrant, verify authentication, tạo demo data, cấu hình Nginx nếu đang ở proxy mode và chạy health check.

Public endpoint **không** tự bật trừ khi người dùng cấu hình chủ động.

## 3. Setup cố định mode/profile

VM/Codespaces 8 GB rootless:

```bash
QDRANT_PROFILE=balanced-memory \
PROCESS_MODE=current-user \
DEPLOYMENT_MODE=minimal \
bash qdrant.sh setup
```

Root + service-user + single-port proxy:

```bash
sudo -E env \
  PROCESS_MODE=service-user \
  DEPLOYMENT_MODE=proxy \
  QDRANT_PROFILE=balanced \
  bash qdrant.sh setup
```

## 4. Endpoint

Minimal mode:

```text
REST + Dashboard: http://127.0.0.1:6333
Dashboard:        http://127.0.0.1:6333/dashboard
```

Proxy mode:

```text
Qdrant internal:  http://127.0.0.1:6333
REST proxy:       http://127.0.0.1:9090
Dashboard:        http://127.0.0.1:9090/dashboard
```

Optional gRPC:

```text
127.0.0.1:6334
```

## 5. Status, log và metrics

```bash
bash qdrant.sh status
bash qdrant.sh health
bash qdrant.sh system-info
bash qdrant.sh metrics
```

`system-info` cho biết runtime path. Log thường nằm ở:

```bash
tail -n 100 "$BASE_DIR/logs/qdrant.log"
tail -n 100 "$BASE_DIR/logs/cloudflared.log"
```

Các management command có thể tìm lại runtime path từ `.qdrant-base`. Với code mẫu/client trong terminal mới, chỉ cần `source scripts/activate.sh`; helper sẽ export `BASE_DIR`, `QDRANT_URL` và runtime key nhưng không in giá trị key.

## 6. Credential

```bash
bash qdrant.sh credentials status
```

Load key cho code mẫu shell:

```bash
source scripts/activate.sh
```

Trong terminal mới, ưu tiên `source scripts/activate.sh`, không cần tự tìm `BASE_DIR`.

Ứng dụng chỉ query nên ưu tiên `QDRANT_READ_ONLY_API_KEY`. Xem [SECURITY.vi.md](SECURITY.vi.md) về rotation/JWT.

## 7. REST API cơ bản

Đặt URL do health/system-info in ra, ví dụ:

```bash
export QDRANT_URL=http://127.0.0.1:6333
source scripts/activate.sh
```

Tạo collection:

```bash
curl -fsS -X PUT \
  -H "api-key: $QDRANT_API_KEY" \
  -H 'Content-Type: application/json' \
  "$QDRANT_URL/collections/books" \
  -d '{"vectors":{"size":4,"distance":"Cosine"}}' | jq .
```

Upsert:

```bash
curl -fsS -X PUT \
  -H "api-key: $QDRANT_API_KEY" \
  -H 'Content-Type: application/json' \
  "$QDRANT_URL/collections/books/points?wait=true" \
  -d '{"points":[{"id":1,"vector":[0.9,0.1,0.1,0.1],"payload":{"title":"Book A"}}]}' | jq .
```

Query bằng read-only key:

```bash
curl -fsS -X POST \
  -H "api-key: $QDRANT_READ_ONLY_API_KEY" \
  -H 'Content-Type: application/json' \
  "$QDRANT_URL/collections/books/points/query" \
  -d '{"query":[0.8,0.2,0.1,0.1],"limit":2,"with_payload":true}' | jq .
```

## 8. Code mẫu

```bash
bash qdrant.sh examples
```

Hoặc chạy riêng cURL/Python/Node/Ruby. Xem [../examples/README.vi.md](../examples/README.vi.md).

## 9. Public access

Khởi động service local trước:

```bash
bash qdrant.sh start
bash qdrant.sh public
```

Trên GitHub Codespaces, `auto` dùng forwarded port của platform. Ở các môi trường mặc định khác có thể dùng Cloudflare Quick Tunnel. Tắt public riêng:

```bash
bash qdrant.sh public-stop
```

Public access không vô hiệu hóa authentication của Qdrant.

## 10. Start/stop/restart

```bash
bash qdrant.sh start
bash qdrant.sh stop
bash qdrant.sh restart
bash qdrant.sh status
```

`start` và `restart` chỉ trả về thành công sau khi authenticated Qdrant REST API đã sẵn sàng. Process liveness và API readiness là hai trạng thái riêng: nếu PID file trỏ tới process còn sống nhưng endpoint `/collections` chưa truy cập được, lệnh sẽ tiếp tục chờ thay vì khởi động process trùng hoặc báo thành công. Trường hợp này thường xảy ra khi Qdrant load hoặc recovery các collection hiện có sau cold start, nhưng bounded wait cũng bảo vệ caller trước process cứ ở trạng thái chưa ready. Các lỗi kết nối curl tạm thời từ readiness probe sẽ không bị in ra màn hình.

Startup deadline được đo theo wall-clock và mặc định là 300 giây. Có thể override bằng số nguyên dương nếu dataset lớn trên disk cần nhiều thời gian recovery hơn:

```bash
QDRANT_START_TIMEOUT_SECONDS=600 bash qdrant.sh start
```

Mỗi readiness probe bị giới hạn bởi thời gian còn lại trước deadline. Nếu Qdrant thoát trước readiness hoặc hết deadline, lệnh public `qdrant.sh` trả về non-zero, thử in 120 dòng cuối của Qdrant log nếu file có sẵn và luôn báo log path. Theo dõi trực tiếp startup progress bằng:

```bash
source scripts/activate.sh
tail -f "$BASE_DIR/logs/qdrant.log"
```

Qdrant release được pin có thể ghi tiến trình load/recovery collection và khởi tạo HTTP listener trong lúc startup. Không phụ thuộc wording cụ thể của upstream log, recorded PID còn sống nhưng authenticated REST probe chưa thành công vẫn được xem là **chưa ready** cho tới khi probe thành công, process thoát hoặc deadline hết hạn.

Code path dùng khi review lifecycle:

```text
qdrant.sh start
└── scripts/service-manager.sh        dispatch lệnh + truyền exit status
    └── scripts/05_start_qdrant.sh    state machine PID/readiness/deadline
        └── scripts/common.sh         runtime precedence + authenticated health probe
```

Khi thay đổi startup behavior, cần giữ các boundary này đồng bộ: start script chịu trách nhiệm chờ và chẩn đoán, còn service manager phải giữ nguyên success hoặc failure cho lệnh public.

Ingress public cố tình được quản lý riêng.

## 11. Runtime settings được lưu

Cấu hình không chứa secret nằm ở `$BASE_DIR/runtime.env`. Có thể override cho một lần chạy bằng environment variables. Chạy lại setup sẽ persist lựa chọn mới.

Ví dụ:

```bash
QDRANT_PROFILE=balanced bash qdrant.sh setup
QDRANT_ENABLE_GRPC=1 bash qdrant.sh setup
QDRANT_MAX_REQUEST_SIZE_MB=64 bash qdrant.sh setup
QDRANT_START_TIMEOUT_SECONDS=600 bash qdrant.sh setup
ENABLE_CORS=false bash qdrant.sh setup
```

`QDRANT_START_TIMEOUT_SECONDS` mặc định là `300` và phải chứa số nguyên dương hệ thập phân không có dấu, phần lẻ hoặc số `0` ở đầu. Biến này tuân theo cùng precedence rule với các runtime setting được lưu khác: environment value được chỉ định rõ sẽ thắng cho lệnh hiện tại. Chạy setup với giá trị mới sẽ ghi nó vào `runtime.env` cho các lệnh lifecycle sau này.

## 12. Backup và recovery

```bash
bash qdrant.sh snapshots create-collection portable_demo
bash qdrant.sh backup collection portable_demo /path/to/durable-backups
bash qdrant.sh backup full /path/to/durable-backups
```

Xem [SNAPSHOTS.vi.md](SNAPSHOTS.vi.md).

## 13. Benchmark host hạn chế tài nguyên

```bash
bash qdrant.sh benchmark --points 10000 --dimension 768
```

Kiểm tra:

```bash
bash qdrant.sh system-info
bash qdrant.sh metrics
```

Với Codespaces 8 GB, `auto` hiện chọn `balanced-memory`; khi muốn A/B với `low-memory`, nên dùng fresh reinstall giữa hai lần chạy để loại ảnh hưởng của data/log/cache/runtime cũ.


## Gợi ý profile theo dataset

```bash
bash qdrant.sh profile-advisor --points 100000 --dimension 768
```

Advisor chỉ đọc/thống kê, không sửa config và không restart Qdrant.

## Benchmark suite

```bash
bash qdrant.sh benchmark-suite
# quick smoke test
bash qdrant.sh benchmark-suite --quick
```

Xem `benchmarks/README.vi.md` để biết chi tiết về repeat, warm-up, settle và percentile.

## 14. Fresh reinstall dành cho test

`cleanup` mặc định giữ nguyên dữ liệu:

```bash
bash qdrant.sh cleanup
```

Chỉ với instance benchmark/test có thể xóa, dùng fresh reinstall:

```bash
bash qdrant.sh reinstall-test
# non-interactive sau khi xác nhận BASE_DIR
bash qdrant.sh reinstall-test --yes
```

Dùng `reset-test --yes` nếu chỉ muốn xóa runtime mà chưa cài lại. `BASE_DIR` chưa tồn tại hoặc rỗng là fresh target an toàn và không cần marker; runtime Qdrant cũ non-empty chưa có marker cần thêm `--force-unmanaged`. Xem [RESET-REINSTALL.vi.md](RESET-REINSTALL.vi.md).

## 15. Smart benchmark có thể so sánh

Flow validation portable chuẩn:

```bash
BENCHMARK_REQUIRE_CLEAN_SOURCE=1 \
CLEAN_REINSTALL=1 \
bash run-smart-qdrant-benchmarks.sh
```

Với CI/automation cần từ chối suite provisional/incomplete:

```bash
BENCHMARK_REQUIRE_READY=1 \
BENCHMARK_REQUIRE_CLEAN_SOURCE=1 \
CLEAN_REINSTALL=1 \
bash run-smart-qdrant-benchmarks.sh
```

Result ZIP có `benchmark-status.json`, `benchmark-acceptance.json`, `source-integrity.json` và các file continuous resource monitor. Nếu archive kết quả cũ như `qdrant-benchmarks-*.zip` hoặc `profile-ab-*.zip` được copy vào project tree, source integrity vẫn giữ run `CLEAN` và ghi các đường dẫn đó vào `ignored_generated_files`; thay đổi source thật vẫn bị từ chối. Xem [../benchmarks/README.vi.md](../benchmarks/README.vi.md).
