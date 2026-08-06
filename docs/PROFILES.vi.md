# Resource Profiles

> 🌐 Language / Ngôn ngữ: [English](PROFILES.md) | **Tiếng Việt**

Profile là preset tương đối bảo thủ, không phải giới hạn phần cứng tuyệt đối. Dataset, dimension/datatype của vector, payload, filesystem, indexing và concurrency mới quyết định mức tài nguyên thực tế.

## Auto selection

Khi chưa biết kích thước dataset, `QDRANT_PROFILE=auto` dùng mặc định theo effective memory. Effective memory là `min(host MemTotal, finite cgroup memory limit)`, giúp tránh chọn profile dùng RAM quá mạnh trong container/notebook bị quota thấp hơn RAM host nhìn thấy:

- `low-memory`: <= 5.5 GB RAM;
- `balanced-memory`: >5.5 GB và <=10.5 GB;
- `balanced`: >10.5 GB và <=22 GB;
- `performance`: >22 GB.

`balanced-lite` vẫn được giữ như lựa chọn disk-first khi collection quá lớn để giữ full vector trong RAM an toàn. Nó không phải lựa chọn tự động cho 4 GB vì benchmark cho thấy cold latency gần như không cải thiện so với `low-memory` khi vector vẫn nằm trên disk.

Mặc định cho máy 8 GB đã đổi từ `balanced-lite` sang `balanced-memory` sau benchmark thực tế: 100K×768 vẫn còn rất nhiều RAM headroom, trong khi vector on-disk có thể gây cold-query latency rất cao trên một số hosted filesystem.

## Advisor theo dataset

Khi biết collection dự kiến, dùng:

```bash
bash qdrant.sh profile-advisor --points 100000 --dimension 768
```

Cho automation/JSON:

```bash
bash qdrant.sh profile-advisor --points 100000 --dimension 768 --json
```

Advisor tính chính xác raw-vector footprint và thêm một budgeting heuristic bảo thủ cho working set. Lệnh này **không thay đổi** Qdrant đang chạy.

## low-memory

Dành cho host hạn chế, đặc biệt khoảng 2-5.5 GB hoặc dataset lớn so với RAM:

- Low Memory Mode `no_populate`;
- vector trên disk;
- HNSW trên disk;
- payload trên disk;
- giới hạn concurrency search/optimizer/indexing.

RSS thấp nhưng cold-query có thể chậm cho đến khi mmap/page cache nóng.

## balanced-lite

Lựa chọn trung gian ưu tiên disk:

- startup memory bình thường;
- vector trên disk;
- payload trên disk;
- HNSW trong RAM;
- indexing/optimization bảo thủ.

Dùng khi `balanced-memory` không còn đủ RAM headroom cho kích thước vector dự kiến.

## balanced-memory

Mặc định mới cho máy khoảng 6-10 GB với collection nhỏ/vừa:

- startup memory bình thường;
- vector trong RAM;
- HNSW trong RAM;
- payload trên disk;
- indexing/optimization vẫn bảo thủ.

Mục tiêu là đổi thêm một ít RAM lấy cold-query latency ổn định hơn — đúng với kết quả benchmark máy 8 GB.

## balanced

Dành cho host khoảng 10-22 GB:

- vector/HNSW ưu tiên RAM;
- payload trên disk;
- optimizer/search thread bình thường.

## performance

Dành cho máy dư RAM và local storage nhanh; vector/HNSW/payload ưu tiên RAM. Nên benchmark trước khi chọn.

## So sánh A/B sạch

Với instance test/benchmark có thể xóa, ưu tiên helper có kiểm soát thứ tự. Mỗi profile được fresh reinstall và cycle thứ hai có thể đảo thứ tự để giảm sequence bias:

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

`reinstall-test` là destructive command, tách riêng khỏi setup/cleanup bình thường. Xem [RESET-REINSTALL.vi.md](RESET-REINSTALL.vi.md).
