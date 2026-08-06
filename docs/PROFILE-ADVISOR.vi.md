# Profile Advisor

> 🌐 Language / Ngôn ngữ: [English](PROFILE-ADVISOR.md) | **Tiếng Việt**

`profile-advisor` giúp chọn resource profile dựa trên **effective memory limit** và, nếu có, kích thước collection dự kiến.

```bash
bash qdrant.sh profile-advisor --points 100000 --dimension 768
```

Effective memory là giá trị nhỏ hơn giữa `MemTotal` mà host hiển thị và finite cgroup memory limit. Điều này quan trọng với container/notebook VM vì process có thể nhìn thấy nhiều RAM hơn quota thực tế được phép dùng. JSON output có các trường:

```text
memory_total_mb
effective_memory_limit_mb
effective_memory_source
hardware_default_profile
recommended_profile
```

Với float32, raw-vector footprint chính xác là `points × dimension × 4 bytes`. Tool sau đó dùng budgeting heuristic bảo thủ để chừa RAM cho HNSW, payload/index metadata, optimizer, OS, Qdrant và filesystem cache.

Heuristic này không phải cam kết chính xác về RAM của Qdrant; mức dùng thật còn phụ thuộc config collection và workload.

Với effective memory <=5.5 GB, advisor giữ mặc định `low-memory` đã được chứng minh cho đến khi A/B có kiểm soát cho đủ evidence để thay đổi theo workload. Tool không tự đẩy sang `balanced-lite` chỉ vì vector set nhỏ, vì benchmark lịch sử cho thấy chỉ giữ HNSW trong RAM trong khi vector vẫn ở disk gần như không giải quyết cold latency.

Advisor không sửa config và không restart Qdrant. Dùng `benchmark-profiles` cho A/B destructive trên instance test có thể xóa.
