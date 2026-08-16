# Tính năng & ma trận khả năng

> 🌐 Language / Ngôn ngữ: [English](FEATURES.md) | **Tiếng Việt**

Trang này là **tổng quan khả năng public** của Qdrant Native Portable `1.0.0`. Nó tổng hợp những gì repository hiện đã cung cấp và dẫn tới các tài liệu chuyên đề — là nơi giữ chi tiết cấu hình làm source of truth.

Project theo hướng **native-first, có Docker và chủ động single-node**. Mục tiêu là notebook, development workspace, Linux host hạn chế tài nguyên, integration environment và deployment single-node theo hướng production.

## Cách hiểu trạng thái

Các bảng dưới đây dùng bốn mức bằng chứng để tránh việc chữ "supported" khiến mọi môi trường trông như có cùng độ trưởng thành:

- **Được hỗ trợ** — implementation và workflow đã có trong public source.
- **Đã regression-test** — test trong repository kiểm tra hành vi hoặc packaging contract liên quan.
- **Đã xác thực trên host thực** — native/runtime path đã được chạy trên nhóm hosted environment được nêu.
- **Đã xác thực trên provider thực** — lifecycle và persistence của provider đã được chạy với provider thật và dữ liệu Qdrant thật.

Các nhãn này mô tả bằng chứng của project, không phải SLA hay bảo đảm từ Qdrant hoặc nhà cung cấp cloud.

## Ma trận khả năng và nền tảng

| Môi trường / target | Runtime path | Storage / persistence | Mức bằng chứng |
|---|---|---|---|
| Google Colab | Native, thường `service-user + proxy` | Runtime ephemeral; export/restore snapshot hoàn tất riêng | Đã xác thực trên host thực |
| Kaggle Notebook | Native, `service-user/proxy` khi có root phù hợp | Phụ thuộc semantics storage/session của notebook | Được hỗ trợ + regression-test platform logic |
| GitHub Codespaces | Native rootless `current-user + minimal` | Phụ thuộc vòng đời workspace | Đã xác thực trên host thực |
| Linux VM kiểu CodeSandbox | Native rootless `current-user + minimal` | Phụ thuộc vòng đời VM/platform | Đã xác thực trên host thực |
| Generic Linux / VPS | Native | Live DB trên local/block POSIX storage tương thích | Được hỗ trợ + regression-test production policy |
| Generic Docker host | Docker | Live DB trên Docker volume/storage driver tương thích | Đã regression-test Docker production path |
| Hugging Face Spaces | Docker | Live DB cục bộ + full snapshot trên Bucket | **Real-provider validated** |
| Modal.com | Docker | Live DB cục bộ + full snapshot trên Modal Volume | **Real-provider validated** |
| Beam.cloud | Docker | Live DB cục bộ + full snapshot trên Beam Volume | **Real-provider validated** |

Với cấu hình và giới hạn theo từng provider, xem [Single-node production](PRODUCTION.vi.md). Với default của môi trường native, xem [Platforms](PLATFORMS.vi.md).

## Ma trận mức độ sẵn sàng production

| Target | Vai trò dự kiến | Persistence posture | Ranh giới quan trọng |
|---|---|---|---|
| Generic Linux/VPS | Production single-node | Live storage block/POSIX tương thích | Operator chịu trách nhiệm durability của host/storage |
| Generic Docker | Production single-node | Docker volume tương thích | Storage driver/filesystem phải phù hợp yêu cầu của Qdrant |
| Colab | Production-demo / development | Ephemeral nếu không export snapshot | Notebook termination nằm ngoài khả năng kiểm soát của project |
| Kaggle | Production-demo / production-light | Phụ thuộc notebook/session storage | Cần coi durability là đặc tính phụ thuộc platform |
| Codespaces | Integration / production-demo | Phụ thuộc vòng đời workspace | Public forwarding là ingress dành cho development |
| Hugging Face Spaces | Persistent production-demo / integration | Live DB cục bộ + full snapshot trên Bucket | **Real-provider validated** |
| Modal.com | Persistent production-demo / integration | Live DB cục bộ + full snapshot trên Modal Volume | **Real-provider validated** |
| Beam.cloud | Persistent production-demo / integration | Live DB cục bộ + full snapshot trên Beam Volume | **Real-provider validated** |

### Mức validation của Modal

Modal có bằng chứng provider-specific mạnh nhất trong release này. Validation trên provider thực đã đi qua fresh write, periodic full snapshot, natural scale-down, exit-hook Volume commit, fresh-container startup, restore snapshot hợp lệ mới nhất, recovery collection và khôi phục đúng point/payload. Cadence periodic được cấu hình là 600 giây và định nghĩa nominal durability RPO; shutdown snapshot bị chủ động tắt vì provider termination và exit hook xảy ra đồng thời.

Operational contract đầy đủ nằm trong [PRODUCTION.vi.md](PRODUCTION.vi.md#modalcom).

### Mức validation của Beam

Beam hiện đã real-provider validated cho đường snapshot-persistence single-node đã tài liệu hóa, gồm recreation/restore, newest-valid selection, corrupt-newest fallback, all-corrupt fail-closed, retention và post-test recovery. Xem [PRODUCTION.vi.md](PRODUCTION.vi.md#beamcloud) để biết contract riêng của provider.

## Khả năng runtime và lifecycle

| Khả năng | Có | Ghi chú / source of truth |
|---|---:|---|
| Qdrant native không cần Docker | Có | [Sử dụng](USAGE.vi.md), [Platforms](PLATFORMS.vi.md) |
| Rootless/current-user | Có | Minimal mode không bắt buộc `systemd`, `useradd` hoặc Nginx |
| Service-user isolation tùy chọn | Có | Dùng khi có root và phù hợp với môi trường |
| Minimal direct REST mode | Có | Thường `127.0.0.1:6333` |
| Nginx proxy mode tùy chọn | Có | Thường `127.0.0.1:9090` |
| Local gRPC tùy chọn | Có | REST vẫn là workflow public mặc định |
| Foreground production lifecycle | Có | `production-check`, `prepare`, `serve` |
| Docker production runtime | Có | Reference image/Compose single-node được harden |
| Provider adapters | Có | Hugging Face Spaces, Modal, Beam |
| Nhiều Qdrant writer / autoscaled DB replicas | **Không** | Chủ động nằm ngoài single-node topology |

## Persistence, snapshot và recovery

Qdrant Native Portable tách **live database storage** khỏi **portable durable snapshot storage**.

```text
Native / block-storage path
application
    ↓
Qdrant live DB
    ↓
local/block POSIX filesystem tương thích

Snapshot-persist provider path
container-local live Qdrant DB
    ↓
full snapshot hoàn tất + SHA256
    ↓
durable provider storage
    ↓
cold-start checksum validation + restore
```

Các khả năng đã có:

- tạo collection snapshot và full-storage snapshot;
- backup/export portable kèm checksum và manifest information;
- lựa chọn restore có kiểm tra checksum;
- fail-closed khi persistent snapshot artifact tồn tại nhưng không có bản nào hợp lệ;
- fallback sang snapshot cũ hơn nhưng checksum hợp lệ khi bản mới bị hỏng;
- auto-restore chỉ khi live database directory rỗng;
- retention cho persisted full snapshot;
- snapshot-persistence adapter cho Hugging Face Spaces, Modal và Beam.

Không nên đặt live Qdrant files trên NFS, FUSE, S3/object-backed hoặc distributed mount bất kỳ nếu filesystem semantics của chúng không đáp ứng yêu cầu của Qdrant. Vì vậy provider adapter giữ live database local và chỉ dùng durable provider storage cho snapshot đã hoàn tất.

Xem [Snapshot & recovery](SNAPSHOTS.vi.md) và [Single-node production](PRODUCTION.vi.md).

## Khả năng bảo mật

Các behavior theo hướng bảo mật đã có:

- admin API key và read-only API key;
- inject API key vào process environment thay vì ghi vào `qdrant.yaml`;
- permission hạn chế cho secret file;
- mask credential output và chỉ reveal khi chủ động yêu cầu;
- staged admin-key rotation và read-only-key rotation;
- JWT RBAC tùy chọn với scoped token generation không cần dependency ngoài;
- Strict Mode default cho collection mới;
- `auth-check` kiểm tra hành vi unauthenticated/admin/read-only;
- production secret policy có thể yêu cầu caller inject secret;
- evidence/result collector fail-closed nếu current API-key value lọt vào file được thu thập;
- public release scan credential, runtime artifact, concrete ephemeral tunnel URL và internal development marker.

Xem [Bảo mật](SECURITY.vi.md) và [SECURITY.md cấp repository](../SECURITY.md).

## Vận hành theo tài nguyên

Project có năm resource profile:

```text
low-memory
balanced-lite
balanced-memory
balanced
performance
```

Profile điều khiển trade-off RAM/disk cho vector, HNSW, payload, optimizer/search concurrency và Low Memory Mode. Auto selection dùng host/cgroup memory; cấu hình explicit luôn được ưu tiên.

`profile-advisor` bổ sung gợi ý theo workload dựa trên các giá trị như point count và vector dimension thay vì chỉ nhìn RAM của host.

Xem [Resource profiles](PROFILES.vi.md) và [Profile advisor](PROFILE-ADVISOR.vi.md).

## Diagnostics và benchmark

Toolkit có:

- `doctor`, `health`, `status`, `system-info`, `metrics`, `security-check`, `auth-check`;
- báo cáo platform, CPU, RAM, cgroup, storage và profile hiện tại;
- quick/full benchmark suite;
- timing tách riêng vector generation, JSON encoding, HTTP ingestion và Qdrant processing;
- đo cold/warm query;
- p50/p90/p95/p99, mean, maximum và standard deviation;
- continuous resource telemetry gồm Qdrant RSS, Linux `MemAvailable`, swap growth, pressure time và sampling-gap check;
- adaptive indexing/settle có giới hạn;
- trạng thái so sánh rõ như `READY`, `PROVISIONAL` và các trạng thái khác;
- helper so sánh cross-run và cross-profile;
- one-command fresh-baseline benchmark cho disposable host.

Xem [Benchmark](../benchmarks/README.vi.md).

## Destructive test workflow an toàn

Normal lifecycle command giữ dữ liệu. Các workflow test-only riêng cung cấp hành vi destructive có guardrail:

- `reset-test`;
- `reinstall-test`;
- `purge-all-test`;
- `run-fresh-qdrant-benchmarks.sh --yes`.

Chúng dùng ownership/path recognition, dangerous-path rejection, dry-run/preflight và fail-closed với unknown non-empty candidate. Source repository được bảo vệ khỏi destructive cleanup.

Xem [Xóa sạch/cài lại](RESET-REINSTALL.vi.md).

## Source integrity và release hygiene

Public repository có:

- canonical `SOURCE-MANIFEST.json` source fingerprint;
- phát hiện modified/missing/unexpected source files;
- source-overlay repair rất hẹp cho trường hợp stale extracted file đã biết;
- release packaging loại runtime state, log, cache, credential, snapshot, benchmark output và local pointer;
- normalize permission trong packaged archive;
- scan internal development label và concrete ephemeral tunnel endpoint;
- sinh SHA256 và packaged-byte/source-integrity verification;
- GitHub Actions static/regression checks, với ShellCheck dự kiến chạy trên hosted CI.

## Code mẫu và tài liệu

Có dependency-light example cho:

- cURL;
- Python;
- Node.js;
- Ruby.

Tài liệu English/Vietnamese được duy trì cho các workflow chính về usage, platform, production, security, snapshot, resource profile, reset/reinstall, benchmark và example.

Xem [Code mẫu](../examples/README.vi.md) và [Mục lục tài liệu](README.vi.md).

## Những gì project chủ động không cung cấp

Qdrant Native Portable `1.0.0` **không** claim cung cấp:

- Qdrant cluster discovery hoặc peer orchestration;
- HA, replication, distributed consensus hoặc automatic failover;
- nhiều autoscaled Qdrant writer;
- một universal durable filesystem layer cho mọi cloud provider;
- production TLS/load-balancing/identity infrastructure thay cho ingress stack của hosting platform;
- bảo đảm rằng ephemeral notebook/workspace provider sẽ giữ session đang chạy.

Đây là các ranh giới scope chủ động, không phải cluster feature bí mật còn làm dở.

## Bản đồ tài liệu

| Nhu cầu | Đọc tài liệu |
|---|---|
| Setup đầu tiên và command | [Sử dụng](USAGE.vi.md) |
| Hành vi theo môi trường native | [Platforms](PLATFORMS.vi.md) |
| Production/Docker/provider deployment | [Single-node production](PRODUCTION.vi.md) |
| Key, JWT, Strict Mode | [Bảo mật](SECURITY.vi.md) |
| Backup, snapshot, restore | [Snapshot & recovery](SNAPSHOTS.vi.md) |
| Tuning RAM/disk | [Resource profiles](PROFILES.vi.md) |
| Gợi ý profile theo dataset | [Profile advisor](PROFILE-ADVISOR.vi.md) |
| Destructive test reset/reinstall | [Xóa sạch/cài lại](RESET-REINSTALL.vi.md) |
| Phương pháp benchmark | [Benchmark](../benchmarks/README.vi.md) |
| Client examples | [Code mẫu](../examples/README.vi.md) |
