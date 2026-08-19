# Nhật ký thay đổi

> 🌐 Language / Ngôn ngữ: [English](CHANGELOG.md) | **Tiếng Việt**

Tất cả thay đổi public đáng chú ý của project sẽ được ghi lại trong file này.

## 1.0.0 - 2026-08-18

- Xác thực provider: Hugging Face Spaces, Modal.com và Beam.cloud đã được xác thực trên provider thực cho các path snapshot-persistence single-node đã document; Beam.cloud real-provider validation bao gồm corrupt-newest fallback, hành vi fail-closed khi tất cả snapshot corrupt, khôi phục sau test và giữ lại dữ liệu.


Bản phát hành public đầu tiên.

### Thêm vào

- Qdrant setup native-first cho môi trường development Linux cùng Docker runtime single-node được harden cho các nền tảng cloud/container được chọn.
- Phát hiện nền tảng cho Google Colab, Kaggle, GitHub Codespaces, VM kiểu CodeSandbox và Linux thông thường.
- Mode rootless `current-user` và mode `service-user` privileged tùy chọn.
- Deployment mode `minimal` và Nginx `proxy`.
- Resource profile `low-memory`, `balanced-lite`, `balanced-memory`, `balanced` và `performance` với auto selection theo RAM.
- API key admin/read-only, staged admin-key rotation, JWT RBAC tùy chọn, masked credential output và security check.
- gRPC tùy chọn, Strict Mode mặc định, snapshot, backup/export, quản lý service, public-access helper, chẩn đoán, metrics và code mẫu.
- Benchmark tooling portable với environment metadata, đo cold/warm query riêng biệt, settle check stable/full-index, timeout thích nghi, chạy lặp lại, mẫu latency thô, percentile reporting, log suite nội bộ và báo cáo suite Markdown/JSON.
- Lệnh reset/reinstall test-only có guardrail xóa sạch runtime data/log/cache/binary cũ trước khi cài mới benchmark trong khi giữ các lệnh vòng đời thông thường không destructive.
- Lệnh `purge-all-test` host-wide và entrypoint fresh benchmark một lệnh cho host validation dùng một lần trên nhiều nền tảng, với runtime/export path riêng theo từng platform.
- Xử lý source-overlay theo hướng fail-closed cho fresh benchmark: có thể nhận diện các đường dẫn legacy đã biết, nhưng chỉ tự động xóa khi có SHA256 kỳ vọng đáng tin cậy và khớp chính xác; source đã sửa, thiếu, không xác định hoặc không thể xác minh đều bị từ chối.
- Tài liệu tiếng Anh và tiếng Việt, bao gồm ma trận khả năng/nền tảng public, tổng quan production-readiness và bản đồ tài liệu.
- GitHub Actions static checks và xác thực release artifact.
- Production policy fail-closed single-node với `production-check`, `prepare` và lifecycle foreground `serve`.
- Docker adapter cho Hugging Face Spaces, Modal và Beam, với autoscaling/cluster behavior cố ý bị vô hiệu hóa trên database node.
- Hugging Face Storage Bucket persistence ở chế độ `snapshot-persist`: live Qdrant data cục bộ, periodic full-storage snapshot có checksum-verified trong Bucket đính kèm, tự động restore, giữ lại, corruption fallback và snapshot khi shutdown có giới hạn.
- Modal single-node snapshot-persist adapter: live Qdrant data cục bộ, full snapshot hoàn tất trên Modal Volume, provider-native commit/read-back durability preflight, periodic cadence 600 giây đã được xác thực an toàn trước cửa sổ scale-down 900 giây, timing margin bắt buộc, secret-free exit/child/commit lifecycle observability và writer limit cứng `max_containers=1`. Real-provider validation ngày 2026-08-18 đã chứng minh chuỗi fresh-write durability hoàn chỉnh: sentinel mới ghi đã sống sót qua scale-down/tái tạo sau hai periodic full snapshot hoàn tất; exit hook đã hoàn tất Volume commit cuối cùng, container mới đã restore snapshot hợp lệ mới nhất và chính xác sentinel point/payload đã được khôi phục. Shutdown snapshot của Modal cố ý bị vô hiệu hóa vì provider termination chạy đồng thời với exit hook; periodic snapshot xác định durability RPO <=600 giây.
- Modal validation-result collector ghi evidence ra ngoài source tree theo mặc định, ghi lại bằng chứng Qdrant collection/sentinel read-only cùng provider log và Volume listing, và từ chối package giá trị API-key hiện tại nếu chúng xuất hiện trong file đã thu thập.
- Hardening full-snapshot restore cho Qdrant 1.18.3: fail closed khi tất cả persisted snapshot không hợp lệ, tránh ép `storage.temp_path` trong quá trình snapshot restore và fail nhanh khi Qdrant child thoát trước khi readiness.
- Mode `direct-mount-experimental` rõ ràng để test Bucket-backed live storage mà không bypass Qdrant filesystem-safety check.

### Độ tin cậy và biện pháp bảo đảm release-quality

- Health check trả về non-zero khi Qdrant API không khả dụng hoặc khi proxy bắt buộc không healthy.
- Native service startup phân biệt PID liveness với authenticated REST readiness, chờ theo wall-clock deadline 300 giây có thể cấu hình trong lúc collection recovery, giới hạn probe theo thời gian còn lại, ẩn lỗi kết nối curl tạm thời và fail sớm nếu process thoát.
- Startup failure giữ exit status non-zero xuyên suốt public service-manager entry point, với lifecycle regression coverage cho delayed readiness, early exit, wall-clock timeout cùng validation, precedence và persistence của runtime setting.
- Runtime artifact, log, cache, benchmark data được tạo, local pointer và credential bị loại khỏi release archive.
- Release packaging ưu tiên source đã Git track trong Git checkout chuẩn; bên ngoài Git, SOURCE-MANIFEST.json hiện có được xác minh và dùng làm nguồn authority chính xác cho source files, với danh sách public-file explicit chỉ giữ lại làm compatibility fallback khi không có manifest chuẩn.

### Cải thiện benchmark/profile

- Thêm `balanced-memory` cho host 6-10 GB với collection nhỏ/trung bình.
- Thêm `profile-advisor` theo dataset với JSON output.
- Thêm settle extension có progress awareness và báo cáo `READY` / `PROVISIONAL` rõ ràng.
- Thêm báo cáo wall-time và cumulative settle-time cho suite/run.
- Thêm benchmark orchestrator cross-platform thông minh vào public source archive.
- Thêm provenance fresh-baseline rõ ràng (`fresh_baseline` / `baseline_origin`) để workflow `purge-all-test` fresh thành công có thể so sánh được mà không cần cài lại lần hai redundantly.
- Cải thiện continuous resource telemetry để phân biệt swap có sẵn với swap growth trong cửa sổ benchmark, loại bỏ pressure transition/event trùng lặp, báo cáo MemAvailable percentile cộng thời gian under pressure, phát hiện sampling gap và phân biệt Qdrant zombie có sẵn với zombie growth trong cửa sổ benchmark.
