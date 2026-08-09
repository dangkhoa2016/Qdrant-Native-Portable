# Bộ benchmark

> 🌐 Language / Ngôn ngữ: [English](README.md) | **Tiếng Việt**

Benchmark Python không cần dependency ngoài, dành cho **đo lường development lặp lại trên host hạn chế tài nguyên**; không thay thế production load test có concurrency.

## Các pha đo

Mỗi repeat chạy:

1. sinh vector deterministic;
2. JSON encoding;
3. HTTP ingestion vào Qdrant;
4. chờ collection green, optimizer idle và state không đổi qua nhiều poll;
5. đo **cold query trước warm-up**;
6. warm-up bằng **chính tập query deterministic sẽ đo**;
7. đo warm query.

Workload chuẩn 50K/100K còn yêu cầu `indexed_vectors_count >= points_count`. Settle timeout mặc định tự thích nghi: 120s <=10K, 180s <=50K, 300s cho 100K.

## Một workload

```bash
bash qdrant.sh benchmark \
  --points 10000 \
  --dimension 768 \
  --queries 100 \
  --cold-queries 20 \
  --warmup 100 \
  --repeat 3
```

Các option hữu ích: `--batch-size`, `--cold-queries`, `--queries`, `--warmup`, `--repeat`, `--settle-timeout`, `--settle-poll`, `--stable-polls`, `--require-full-index`, `--skip-settle`, `--keep`, `--no-raw-latencies`, `--output`.

`--warmup` là số request; nó lặp qua chính IDs của warm measured query. Đặt warmup >= queries để mỗi measured query được warm ít nhất một lần.

## Standard suite

```bash
bash qdrant.sh benchmark-suite
```

Gồm 1K×384, 10K×768, 50K×768, 100K×768. Mặc định: repeat=3, cold=20, warm measured=50 và 50 same-set warm-up requests.

Kiểm tra nhanh:

```bash
bash qdrant.sh benchmark-suite --quick
```

Mỗi suite tự ghi `benchmark-suite.log`, JSON từng workload, `benchmark-report.json` và `benchmark-report.md` dưới `$BASE_DIR/benchmarks/suite-.../`, không phụ thuộc hoàn toàn vào terminal capture của platform.

## Đọc kết quả

- **Cold p50/p95/max** cho thấy chi phí mmap/page-cache và on-disk index.
- **Warm p50/p95/p99/max** đo cùng tập query sau warm-up.
- **HTTP ingest pts/s** loại client vector generation/JSON encoding.
- **Pipeline pts/s** bao gồm toàn bộ generation + encoding + HTTP + Qdrant.
- **Ready runs** đã pass green + optimizer idle + stable-state; 50K/100K còn yêu cầu full indexing.
- **Peak Qdrant RSS** chỉ là checkpoint sampling.
- **Minimum available RAM** lấy từ Linux `MemAvailable`.

## So sánh sạch

Khi A/B profile, data/log/cache/runtime cũ có thể làm sai kết luận. Dùng fresh reinstall dành riêng cho test giữa hai lần:

```bash
QDRANT_PROFILE=low-memory bash qdrant.sh reinstall-test --yes
bash qdrant.sh benchmark-suite --quick

QDRANT_PROFILE=balanced-lite bash qdrant.sh reinstall-test --yes
bash qdrant.sh benchmark-suite --quick
```

Không dùng destructive reinstall với dữ liệu quan trọng. Setup/cleanup thông thường luôn giữ storage.

## Adaptive settle và kết quả provisional

Standard suite dùng settle window có giới hạn và theo dõi progress. Mặc định initial/max là 120/180 giây cho <=10K, 180/300 cho 50K và 300/480 cho 100K. Nếu indexing vẫn tiến triển khi gần chạm initial deadline, benchmark có thể gia hạn đến maximum.

`benchmark-report.md` đánh dấu từng workload `READY` hoặc `PROVISIONAL`, ghi tổng settle time/run wall time và số repeat đã phải gia hạn timeout. Không nên xếp hạng một workload `PROVISIONAL` ngang với workload mà mọi repeat đều benchmark-ready.

## Run portable theo chuẩn validation

Để tạo baseline có thể so sánh trên hosted VM, ưu tiên fresh entrypoint một lệnh từ canonical release đã giải nén:

```bash
bash run-fresh-qdrant-benchmarks.sh --yes
```

Parent wrapper purge an toàn runtime state mà project nhận diện rồi truyền provenance rõ ràng sang smart wrapper. `clean_reinstall=0` chỉ có nghĩa smart wrapper không chạy lại reinstall lần thứ hai; `fresh_baseline=1` và `baseline_origin=purge-all-test` mới là semantic freshness dùng để quyết định comparability. Flow cũ chạy trực tiếp smart wrapper với `BENCHMARK_REQUIRE_CLEAN_SOURCE=1 CLEAN_REINSTALL=1` vẫn được hỗ trợ.

Thêm `BENCHMARK_REQUIRE_READY=1` nếu automation cần trả non-zero khi suite là `PROVISIONAL`, thiếu, không xác định hoặc bị skip vì memory safety. Wrapper vẫn package diagnostics trước khi trả strict exit code.

Result bundle chứa source integrity, bằng chứng runtime authorization, continuous resource telemetry, benchmark readiness/comparability và acceptance verdict. Artifact tốt để so sánh có dạng:

```text
READY
+ source integrity CLEAN
+ fresh baseline provenance
= CLEAN_BASELINE
+ đủ runtime evidence
= ACCEPTED_BASELINE hoặc ACCEPTED_WITH_WARNINGS
```

`ACCEPTED_WITH_WARNINGS` vẫn đủ điều kiện so sánh. Resource telemetry tách swap có sẵn khi benchmark bắt đầu khỏi swap tăng trong benchmark, log pressure theo transition/delta thay vì lặp trạng thái không đổi, đồng thời ghi MemAvailable p01/p05/median và thời lượng pressure quan sát được. Telemetry cũng ghi tính liên tục của sampling: gap dài được tính là khoảng thời gian monitor không quan sát được, bị loại khỏi phép tính pressure-duration, và được cảnh báo theo dạng host-pause-or-monitor-stall khi đủ lớn. Zombie Qdrant vẫn được ghi riêng khỏi live RSS, kèm start/end/maximum và mức tăng trong cửa sổ benchmark để trạng thái có sẵn của host không bị hiểu nhầm thành regression.

## Source integrity

Public source archive có `SOURCE-MANIFEST.json`. Kiểm tra tree sau khi giải nén:

```bash
bash qdrant.sh source-integrity check \
  --root . \
  --require-clean \
  --json-output source-integrity.json
```

Các file runtime/generated như `.qdrant-base`, log, interpreter cache và runtime secret không thuộc canonical source fingerprint. Các archive kết quả benchmark có tên `qdrant-benchmarks-*.zip(.sha256)` hoặc `profile-ab-*.zip(.sha256)` cũng không tham gia fingerprint và được ghi riêng trong `ignored_generated_files`; nhờ đó việc copy result ZIP vào working tree không làm một source canonical thành `DIRTY`. Phạm vi ignore được giữ cố ý rất hẹp: ZIP tùy ý hoặc source/config mới vẫn làm integrity thành `DIRTY`.

## A/B profile có kiểm soát thứ tự

```bash
bash qdrant.sh benchmark-profiles \
  --yes \
  --require-clean-source \
  --profiles low-memory,balanced-lite,balanced-memory \
  --order alternate \
  --cycles 2 \
  --points 100000 \
  --dimension 768
```

`profile-comparison.md` tách benchmark checkpoint RAM và continuous-monitor RAM, đồng thời ghi Qdrant RSS, telemetry continuity/max-gap/missing-time, swap start/max/growth, pressure sample/event và zombie start/max/growth.

## So sánh artifact nhiều host

Có thể so sánh run directory hoặc benchmark ZIP mà không vô tình xếp hạng run dirty/provisional:

```bash
bash qdrant.sh compare-benchmarks \
  --json-output compare.json \
  --markdown-output compare.md \
  result-a.zip result-b.zip result-c.zip result-d.zip
```

Chỉ run được chấp nhận như clean comparable baseline mới vào ranking cold-p50. Run bị loại vẫn xuất hiện cùng lý do.
