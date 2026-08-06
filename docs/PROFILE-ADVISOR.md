# Profile Advisor

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](PROFILE-ADVISOR.vi.md)

`profile-advisor` helps choose a resource profile using the **effective memory limit** and, when supplied, an expected collection size.

```bash
bash qdrant.sh profile-advisor --points 100000 --dimension 768
```

Effective memory is the lower of visible host `MemTotal` and a finite cgroup memory limit. This matters on containers/notebook VMs that may expose more host RAM than the process is actually allowed to use. JSON output includes:

```text
memory_total_mb
effective_memory_limit_mb
effective_memory_source
hardware_default_profile
recommended_profile
```

For float32 vectors the exact raw-vector footprint is `points × dimension × 4 bytes`. The tool then applies a conservative project budgeting heuristic to leave room for HNSW, payload/index metadata, optimizer work, the OS, Qdrant itself, and filesystem cache.

The heuristic is intentionally not presented as a Qdrant memory guarantee. Real memory use depends on collection configuration and workload.

For effective memory <=5.5 GB, the advisor keeps the proven `low-memory` default unless future controlled A/B evidence justifies a workload-aware change. The tool does not silently promote `balanced-lite` merely because a small vector set fits: historical testing showed little cold-latency benefit from keeping only HNSW in RAM while vectors remain on disk.

The advisor never changes config or restarts Qdrant. Use `benchmark-profiles` for destructive, disposable A/B validation.
