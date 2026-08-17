# Qdrant Native Portable

> 🌐 Language / Ngôn ngữ: [English](README.md) | **Tiếng Việt**

Bộ công cụ Qdrant theo hướng bảo mật, **native-first và có Docker**, dành cho học tập, development, RAG demo, integration test và các deployment single-node theo hướng production. Native mode tự thích nghi với Google Colab, Kaggle, GitHub Codespaces, VM kiểu CodeSandbox và Linux thông thường; Docker runtime bổ sung adapter cho Hugging Face Spaces, Modal và Beam.

> **Phạm vi:** hạ tầng single-node. Project có production policy, foreground lifecycle, Docker hardening và persistence helper theo provider, nhưng chủ động không thay thế một Qdrant cluster production có HA.

## Mục tiêu thiết kế

Bản public được thiết kế để tránh các giả định chỉ dành cho một nền tảng:

- tự phát hiện nền tảng và chọn thư mục dữ liệu phù hợp;
- hỗ trợ **rootless/current-user mode**;
- hỗ trợ **minimal mode** chỉ chạy Qdrant, nên Nginx/root là tùy chọn;
- vẫn giữ Nginx single-port proxy dưới dạng `proxy` mode;
- có năm profile tài nguyên `low-memory`, `balanced-lite`, `balanced-memory`, `balanced`, `performance`;
- bật Qdrant Low Memory Mode trên host hạn chế RAM;
- hỗ trợ gRPC local tùy chọn;
- áp dụng Strict Mode mặc định cho collection mới;
- hỗ trợ JWT RBAC tùy chọn và sinh scoped JWT không cần dependency Python ngoài;
- hỗ trợ Cloudflare Quick Tunnel và publish port của GitHub Codespaces;
- bổ sung `doctor`, `system-info`, `metrics`, export backup và benchmark tài nguyên;
- lưu cấu hình runtime không chứa secret bên ngoài repository;
- bổ sung single-node production policy fail-closed và lifecycle `prepare`/`serve` foreground;
- bổ sung Docker runtime được harden cùng adapter cho Hugging Face Spaces, Modal và Beam;
- hỗ trợ Hugging Face Storage Bucket an toàn ở tầng full-snapshot persistence trong khi live Qdrant data vẫn nằm local.
- bao gồm Beam Volume snapshot-persistence adapter đã xác thực trên provider thực trong khi live Qdrant data vẫn nằm local;

## Vì sao dùng project này?

Phần lớn hướng dẫn bắt đầu với Qdrant giả định có Docker, quyền root hoặc một server chạy lâu dài. Những giả định đó khá bất tiện trên hosted notebook và các môi trường cloud development bị giới hạn. **Qdrant Native Portable biến official native Qdrant binary thành một runtime toolkit có thể tái sử dụng**: auto-detect platform, profile theo tài nguyên, quản lý lifecycle rootless, credential an toàn, diagnostics, snapshot, public ingress tùy chọn, benchmark có khả năng tái lập và destructive test workflow có guardrail đều nằm trong cùng một repository.

Project đặc biệt hữu ích cho:

- developer RAG/semantic search cần một Qdrant disposable chạy cạnh embedding model hoặc application;
- người dùng Colab, Kaggle, Codespaces, CodeSandbox-like và Linux hạn chế quyền khi không thể hoặc không muốn dùng Docker;
- sinh viên, workshop, demo, SDK integration test và các thử nghiệm kiểu CI cần một database single-node có hành vi dễ dự đoán;
- developer muốn so sánh trade-off RAM/disk của Qdrant trên các máy hosted nhỏ và vừa.

Toolkit giữ Qdrant theo hướng CPU/RAM. Trên notebook có GPU, GPU vì vậy có thể dành cho embedding, reranker, LLM hoặc VLM thay vì dùng cho tầng database.

## Ma trận khả năng và nền tảng

Bảng dưới đây là overview public nhanh nhất. Nó tách rõ native notebook/workspace support khỏi Docker provider adapter và thể hiện độ trưởng thành của persistence. Xem [Tổng hợp đầy đủ các khả năng](docs/FEATURES.vi.md) để có feature matrix và định nghĩa mức bằng chứng đầy đủ.

| Target | Runtime | Persistence posture | Bằng chứng |
|---|---|---|---|
| Google Colab | Native | Ephemeral; export/restore snapshot riêng | Đã xác thực trên host thực |
| Kaggle Notebook | Native | Phụ thuộc session/storage | Được hỗ trợ + regression-test platform logic |
| GitHub Codespaces | Native rootless | Phụ thuộc vòng đời workspace | Đã xác thực trên host thực |
| Linux VM kiểu CodeSandbox | Native rootless | Phụ thuộc vòng đời VM/platform | Đã xác thực trên host thực |
| Generic Linux / VPS | Native | Live storage block/POSIX tương thích | Được hỗ trợ + regression-test |
| Generic Docker host | Docker | Docker volume tương thích | Đã regression-test |
| Hugging Face Spaces | Docker | Live DB cục bộ + full snapshot trên Bucket | **Real-provider validated** |
| Modal.com | Docker | Live DB cục bộ + full snapshot trên Modal Volume | **Real-provider validated** |
| Beam.cloud | Docker | Live DB cục bộ + full snapshot trên Beam Volume | **Real-provider validated** |

Bằng chứng persistence mạnh nhất theo provider trong release này là Modal: lifecycle trên provider thực đã khôi phục đúng fresh point/payload sau periodic snapshot, scale-down, fresh container và restore snapshot hợp lệ mới nhất. Xem [Single-node production](docs/PRODUCTION.vi.md#modalcom).

## Project này là gì — và không phải là gì

**Đây là:** một runtime/deployment toolkit Qdrant single-node có thể chạy native không cần Docker khi phù hợp, dùng Docker khi platform ưu tiên container, áp dụng resource-aware profile và security default, tạo/restore snapshot, kiểm tra authorization, benchmark hành vi của host và đóng gói public source sạch.

**Đây không phải là:** Qdrant HA/cluster orchestrator. Release này không cung cấp peer discovery, replication, distributed consensus, automatic failover, nhiều autoscaled Qdrant writer hoặc một universal cloud filesystem abstraction. Object/distributed storage của provider chỉ được dùng khi semantics phù hợp — ví dụ giữ snapshot đã hoàn tất thay vì tùy ý làm live database filesystem.

## Mặc định dựa trên bằng chứng thực tế

Các profile tự động không chỉ là preset theo lý thuyết; chúng đã được tinh chỉnh qua nhiều lần chạy trên Google Colab, GitHub Codespaces và các Linux VM kiểu CodeSandbox. Các số liệu dưới đây là **quan sát trên workload development 100K×768 mà project đã test, không phải cam kết hiệu năng Qdrant áp dụng cho mọi hệ thống**:

- **~4 GB:** `low-memory` đã nhiều lần chạy được mà không xuất hiện pattern OOM, đổi lại first-query latency cao hơn để giữ headroom RAM.
- **~8 GB:** `balanced-memory` giữ vectors + HNSW trong RAM và đạt khoảng **cold p50 lớp 2–3 ms** trong các run đã đo. Baseline `balanced-lite` disk-first trước đó trên cùng nhóm host nằm khoảng **0.1–0.8 giây cold p50**, phụ thuộc mạnh vào platform/storage backend.
- **~13 GB Colab:** `balanced` ổn định với headroom RAM lớn. Quá trình benchmark cũng chứng minh vì sao phải tách timing client/server: Python vector generation và JSON encoding có thể chiếm phần lớn wall-clock dù xử lý phía Qdrant server vẫn mạnh.

Các kết quả này dùng để định hướng default cho development, không thay thế việc sizing theo workload thật. Hãy dùng `profile-advisor` với số point và vector dimension của bạn, đồng thời benchmark lại khi đổi Qdrant version, quy mô collection, storage class hoặc payload/index design.

## Default của native mode

| Môi trường | Process mode mặc định | Deployment mặc định | Profile mặc định* | Public access |
|---|---|---|---|---|
| Google Colab | service-user | proxy | dựa theo RAM | Cloudflare Quick Tunnel |
| Kaggle | service-user nếu có root | proxy nếu có root | dựa theo RAM | Cloudflare Quick Tunnel |
| GitHub Codespaces | current-user | minimal | thường là balanced-memory với máy 8 GB | Codespaces forwarding |
| CodeSandbox/Linux VM | current-user | minimal | dựa theo RAM | Quick Tunnel / cơ chế platform |
| Linux thông thường | current-user trừ khi chạy root | minimal trừ khi chạy root | dựa theo RAM | opt-in |

Với `auto`, dự án chọn `low-memory` ở khoảng <=5.5 GB RAM, `balanced-memory` ở <=10.5 GB, `balanced` ở <=22 GB và `performance` khi cao hơn. Giá trị do người dùng chỉ định luôn được ưu tiên.

## Kiến trúc

Minimal/rootless:

```text
client / platform forwarding / optional tunnel
                │
                ▼
       127.0.0.1:6333 Qdrant REST + Dashboard
                │
        storage + snapshots
```

Proxy mode:

```text
client / HTTPS tunnel
        │
        ▼
127.0.0.1:9090 Nginx
        │
        ▼
127.0.0.1:6333 Qdrant
```

API key không được ghi vào `qdrant.yaml`; chúng được inject qua environment khi process Qdrant khởi động.

## Chạy nhanh

```bash
# From the repository root
bash qdrant.sh doctor
bash qdrant.sh setup
```

Sau đó:

```bash
bash qdrant.sh status
bash qdrant.sh health
bash qdrant.sh auth-check
bash qdrant.sh system-info
```

Setup/health sẽ in endpoint local hiện tại. Minimal mode thường dùng `http://127.0.0.1:6333`; proxy mode thường dùng `http://127.0.0.1:9090`.

### GitHub Codespaces 8 GB

Không cần root hoặc Nginx. Với `auto`, Codespace 8 GB hiện chọn `balanced-memory` + `current-user` + `minimal` dựa trên headroom thực tế từ các run 8 GB. Để ép đúng profile:

```bash
QDRANT_PROFILE=balanced-memory \
PROCESS_MODE=current-user \
DEPLOYMENT_MODE=minimal \
bash qdrant.sh setup
```

Với `auto`, Codespace non-root 8 GB thông thường sẽ tự chọn cấu hình tương đương. Để chuyển forwarded port sang public bằng GitHub CLI:

```bash
bash qdrant.sh public
```

Để đưa port trở lại private:

```bash
bash qdrant.sh public-stop
```

## Resource profiles

### `low-memory`

Dành cho host khoảng 2-5.5 GB và VM development hạn chế tài nguyên. Profile này dùng Qdrant startup Low Memory Mode `no_populate`, mặc định đặt vectors/HNSW trên disk, payload trên disk và giảm concurrency của search/optimizer.

```bash
QDRANT_PROFILE=low-memory bash qdrant.sh setup
```

### `balanced-lite`

Lựa chọn disk-first cho host khoảng 6-10 GB khi collection dự kiến quá lớn để giữ full vector trong RAM. Vector/payload nằm trên disk, HNSW trong RAM.

### `balanced-memory`

Mặc định mới cho máy 6-10 GB với collection nhỏ/vừa: vector + HNSW trong RAM, payload trên disk, optimizer vẫn bảo thủ. Mục tiêu là giảm cold-query penalty đã thấy trên một số VM 8 GB.

Khi biết kích thước collection, dùng advisor:

```bash
bash qdrant.sh profile-advisor --points 100000 --dimension 768
```

### `balanced`

Phù hợp cho máy development khoảng 10-22 GB. Payload nằm trên disk, còn vectors/HNSW ưu tiên RAM để latency ổn định hơn.

### `performance`

Dành cho host nhiều RAM và local storage nhanh, ưu tiên hoạt động in-memory và tự chọn thread.

Xem [docs/PROFILES.vi.md](docs/PROFILES.vi.md).

## Bảo mật

Credential nằm ngoài repository tại `$BASE_DIR/secrets.env` với permission `600`. Cấu hình runtime không chứa secret nằm tại `$BASE_DIR/runtime.env`.

```bash
bash qdrant.sh credentials status
bash scripts/show_credentials.sh --reveal   # chỉ khi chủ động cần key thật
```

Rotate key:

```bash
bash qdrant.sh credentials rotate-readonly --restart
bash qdrant.sh credentials stage-admin-rotation --restart
bash qdrant.sh credentials promote-admin-rotation --restart
```

JWT RBAC là opt-in:

```bash
bash qdrant.sh credentials jwt-enable --restart
bash qdrant.sh credentials create-token \
  --scope fairy_tales:r \
  --ttl 3600
```

Token được lưu với mode `600`. Khi rotate admin key, các JWT được ký bằng admin key cũ sẽ mất hiệu lực.

Strict Mode mặc định được áp dụng cho collection mới với giới hạn tương đối bảo thủ cho query/timeout/HNSW. Các giá trị này có thể cấu hình và không nên được hiểu là một multi-tenant security boundary hoàn chỉnh.

Sau setup, hãy kiểm tra trực tiếp authorization semantics của runtime:

```bash
bash qdrant.sh auth-check
```

`auth-check` xác nhận đúng protection path mong đợi: truy cập collection không có credential bị từ chối, admin key đọc được, read-only key đọc được và write bằng read-only key bị từ chối. Như vậy project kiểm tra hành vi authorization chứ không chỉ kiểm tra process Qdrant còn sống.

Xem [docs/SECURITY.vi.md](docs/SECURITY.vi.md).

## gRPC tùy chọn

REST vẫn là mặc định. Bật local gRPC khi cần:

```bash
QDRANT_ENABLE_GRPC=1 bash qdrant.sh setup
```

Qdrant gRPC sẽ bind loopback port `6334`. Nginx single-port proxy của project vẫn chỉ expose REST.

## Code mẫu

Code mẫu được tách khỏi infrastructure code:

```text
examples/
├── curl/
├── python/
├── node/
└── ruby/
```

Nạp runtime hiện tại vào shell mà không in secret:

```bash
source scripts/activate.sh
```

Chạy các ví dụ dependency-light:

```bash
bash qdrant.sh examples
```

Xem [examples/README.vi.md](examples/README.vi.md).

## Backup và snapshot

Trình quản lý snapshot:

```bash
bash qdrant.sh snapshots create-full
bash qdrant.sh snapshots create-collection portable_demo
```

Export backup portable kèm checksum và manifest:

```bash
bash qdrant.sh backup full /path/to/backup-dir
bash qdrant.sh backup collection portable_demo /path/to/backup-dir
```

Không đặt **live Qdrant storage** trực tiếp trên Google Drive/FUSE/network-style storage. Hãy để database đang chạy trên local POSIX filesystem phù hợp rồi copy snapshot hoàn tất sang nơi lưu bền vững.

Xem [docs/SNAPSHOTS.vi.md](docs/SNAPSHOTS.vi.md).

## Chẩn đoán và benchmark

```bash
bash qdrant.sh doctor
bash qdrant.sh system-info
bash qdrant.sh metrics
bash qdrant.sh metrics --raw
```

Benchmark không cần dependency ngoài, có chờ trạng thái ổn định, repeat, tách **cold/warm latency**, metadata host và timing client/server-facing:

```bash
bash qdrant.sh benchmark \
  --points 10000 \
  --dimension 768 \
  --queries 100 \
  --cold-queries 20 \
  --warmup 100 \
  --repeat 3
```

Warm-up dùng chính tập query sẽ đo. Workload 50K/100K trong standard suite còn yêu cầu full indexing trước khi đo.

Chạy standard suite cho host hạn chế tài nguyên (1K×384, 10K×768, 50K×768, 100K×768):

```bash
bash qdrant.sh benchmark-suite
```

Kiểm tra nhanh:

```bash
bash qdrant.sh benchmark-suite --quick
```

Kết quả nằm dưới `$BASE_DIR/benchmarks/`. Suite sinh cả `benchmark-report.json` và `benchmark-report.md`.

### Benchmark readiness và khả năng so sánh

HTTP request chạy thành công chưa đồng nghĩa benchmark đã đủ điều kiện để so sánh. Suite artifact phân biệt các trạng thái như `READY`, `PROVISIONAL`, `MISSING`, `UNKNOWN` và `SKIPPED_MEMORY`. `READY` nghĩa là workload đã đạt các điều kiện benchmark-readiness; `PROVISIONAL` chủ động không được xếp hạng tương đương `READY` khi indexing/optimizer chưa sẵn sàng đầy đủ.

Project cũng tách **readiness** khỏi **comparability**. Workflow dùng cho so sánh có thể xác nhận source sạch, provenance của fresh baseline và acceptance trước khi rank các run:

```bash
bash qdrant.sh benchmark-status --run-dir /path/to/run --require-ready --require-clean-baseline
bash qdrant.sh benchmark-acceptance --run-dir /path/to/run --require-accepted
bash qdrant.sh compare-benchmarks /path/to/run-a /path/to/run-b
```

Với destructive profile A/B, `benchmark-profiles` cài lại từng profile đo trên một disposable runtime sạch và hỗ trợ order/cycle deterministic để giảm ảnh hưởng của thứ tự chạy:

```bash
bash qdrant.sh benchmark-profiles \
  --profiles low-memory,balanced-memory \
  --points 100000 \
  --dimension 768 \
  --yes
```

### Source integrity và provenance của fresh baseline

`SOURCE-MANIFEST.json` định nghĩa canonical public source set. Có thể xác nhận working tree khớp manifest trước khi so sánh kết quả:

```bash
python3 scripts/source-integrity.py check \
  --root . \
  --manifest SOURCE-MANIFEST.json \
  --require-clean
```

Fresh benchmark workflow ghi provenance như `fresh_baseline=1` và `baseline_origin=purge-all-test`, nhờ đó kết quả phân biệt được runtime thực sự vừa được dựng lại với runtime đã tồn tại trước đó. Generated benchmark archive được xử lý tách khỏi canonical source identity; unexpected source file không được nhận diện vẫn làm clean-source gate fail.

### Tính đúng đắn của resource telemetry

Benchmark orchestration có thể theo dõi liên tục Linux `MemAvailable`, RSS của Qdrant/client, swap và cgroup signals. Summary phân biệt telemetry `CONTINUOUS` với `GAPPED`, ghi missing monitor time và không biến khoảng thời gian không có sample thành observed memory pressure. Swap và Qdrant zombie dùng semantics start/end/max/growth để trạng thái đã tồn tại trên host không tự động bị quy cho benchmark.

Xem [benchmarks/README.vi.md](benchmarks/README.vi.md) để biết chi tiết report schema, status/acceptance rules, telemetry fields và workflow so sánh.

## Xóa sạch và cài lại dành cho benchmark/test

Các lệnh `setup`, `start`, `restart` và `cleanup` mặc định **không xóa dữ liệu**. Khi cần xác nhận benchmark trên một runtime hoàn toàn sạch, dùng đường dẫn destructive riêng:

```bash
bash qdrant.sh reinstall-test
```

Chạy non-interactive sau khi đã kiểm tra `BASE_DIR`:

```bash
bash qdrant.sh reinstall-test --yes
```

Chỉ xóa runtime hiện tại mà chưa cài lại:

```bash
bash qdrant.sh reset-test --yes
```

Với các máy benchmark disposable có đường dẫn runtime/export khác nhau theo platform, dùng lệnh purge toàn bộ dữ liệu của project. Lệnh tự phát hiện `BASE_DIR` hiện tại, `.qdrant-base`, đường dẫn mặc định của platform, managed runtime trong các root hẹp và thư mục benchmark export. Destructive operation dùng nhận diện path/ownership cùng **atomic fail-closed preflight**; nếu có một candidate non-empty không được nhận diện, purge dừng trước khi xóa bất kỳ candidate hợp lệ nào thay vì mù quáng tin vào một đường dẫn được cấu hình:

```bash
bash qdrant.sh purge-all-test --yes
```

Muốn xóa sạch rồi cài lại Qdrant ngay:

```bash
bash qdrant.sh purge-all-test --yes --reinstall
```

Để tạo baseline benchmark sạch bằng đúng một lệnh trên Colab, Kaggle, Codespaces, CodeSandbox hoặc generic Linux:

```bash
bash run-fresh-qdrant-benchmarks.sh --yes
```

Entrypoint này trước hết tự sửa một allowlist rất hẹp gồm các stale source file có thể còn lại khi giải nén source mới đè lên source tree cũ, rồi kiểm tra canonical source integrity **trước khi** xóa dữ liệu. Auto-repair vẫn fail-closed: nếu canonical file bị sửa/bị thiếu hoặc có bất kỳ unexpected file lạ nào, workflow dừng mà không xóa source hay runtime. Chỉ sau khi source trở về `CLEAN`, nó mới purge runtime/benchmark state mà project nhận diện an toàn, dựng lại và chạy smart benchmark. Metadata của run ghi `fresh_baseline=1` cùng `baseline_origin=purge-all-test`; `clean_reinstall=0` vẫn chính xác vì smart wrapper không lặp lại destructive reinstall lần thứ hai. Guardrail destructive không bao giờ xóa source repository. Xem [docs/RESET-REINSTALL.vi.md](docs/RESET-REINSTALL.vi.md).

## Giới hạn quan trọng

Project chỉ giữ lại các giới hạn thật sự thay vì biến hạn chế của một platform thành hạn chế của toàn project:

1. **Chỉ single-node.** HA, replication, distributed consensus và cluster orchestration nằm ngoài phạm vi repository.
2. **Storage vẫn quan trọng.** Live database nên dùng block/POSIX storage phù hợp; cloud/FUSE/object-backed mount thích hợp hơn cho backup/snapshot đã hoàn tất. Adapter Hugging Face có thể tự động hóa mô hình snapshot persistence này.
3. **Nền tảng ephemeral vẫn có thể mất runtime.** Project không thể ngăn Colab/Kaggle terminate session; cần export backup trước khi runtime biến mất.
4. **Public endpoint cho demo không phải production ingress.** Quick Tunnel và Codespaces public port đều là cơ chế expose dành cho development.
5. **Rootless mode chủ động bỏ system integration.** Core Qdrant chạy không cần root, nhưng system Nginx proxy và service-user isolation vẫn cần root.
6. **gRPC mặc định là local/advanced.** Reverse proxy single-port tùy chọn của project tập trung vào REST.

Xem [docs/PLATFORMS.vi.md](docs/PLATFORMS.vi.md).

## Chính sách version

Qdrant `1.18.3` vẫn là mặc định vì đây là known-good baseline đã được xác nhận cho project. Hãy test release mới một cách chủ động trước khi đổi default:

```bash
QDRANT_VERSION=1.19.0 bash qdrant.sh setup
```

Nên snapshot dữ liệu quan trọng trước khi thử server version mới.

## Bản đồ tài liệu

| Nhu cầu | Bắt đầu từ |
|---|---|
| Tổng quan đầy đủ capability/status | [Tính năng & ma trận khả năng](docs/FEATURES.vi.md) |
| Setup và command hằng ngày | [Sử dụng](docs/USAGE.vi.md) |
| Hành vi Colab/Kaggle/Codespaces/CodeSandbox/Linux | [Platforms](docs/PLATFORMS.vi.md) |
| Docker, production policy, HF Spaces, Modal, Beam | [Single-node production](docs/PRODUCTION.vi.md) |
| API key, JWT RBAC, Strict Mode | [Bảo mật](docs/SECURITY.vi.md) |
| Snapshot, backup, restore | [Snapshot & recovery](docs/SNAPSHOTS.vi.md) |
| Tuning RAM/disk | [Resource profiles](docs/PROFILES.vi.md) |
| Gợi ý profile theo dataset | [Profile advisor](docs/PROFILE-ADVISOR.vi.md) |
| Destructive test workflow có guardrail | [Xóa sạch/cài lại](docs/RESET-REINSTALL.vi.md) |
| Phương pháp/format benchmark | [Benchmark](benchmarks/README.vi.md) |
| Client cURL/Python/Node/Ruby | [Code mẫu](examples/README.vi.md) |

Xem [mục lục tài liệu đầy đủ](docs/README.vi.md) cho toàn bộ cây tài liệu song ngữ.

## Kiểm tra repository

Repository có regression coverage cho portable/rootless mode, authorization và JWT, benchmark settle/status/acceptance/comparison, source integrity, resource-monitor continuity, guardrail reinstall/purge, secret precedence và release-package hygiene. Nhiều test trong số này tồn tại vì một bug thực tế trên host hoặc trong orchestration đã từng được tái hiện rồi được khóa lại thành regression case.

```bash
bash tests/static-checks.sh
bash qdrant.sh security-check
```

GitHub Actions là môi trường authoritative dự kiến để chạy ShellCheck cho public repository; môi trường local có thể không cài sẵn binary `shellcheck`.

## License

MIT. Xem [LICENSE](LICENSE).
