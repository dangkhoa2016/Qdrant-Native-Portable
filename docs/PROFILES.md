# Resource Profiles

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](PROFILES.vi.md)

Profiles are conservative presets, not hard hardware limits. Dataset size, vector dimensions/datatype, payloads, filesystem behavior, indexing, and concurrency determine real resource use.

## Auto selection

When no dataset size is known, `QDRANT_PROFILE=auto` uses an effective-memory default. Effective memory is `min(host MemTotal, finite cgroup memory limit)`, which prevents over-selecting an in-memory profile inside constrained containers/notebooks:

- `low-memory`: <= 5.5 GB RAM;
- `balanced-memory`: >5.5 GB and <=10.5 GB;
- `balanced`: >10.5 GB and <=22 GB;
- `performance`: >22 GB.

`balanced-lite` remains available explicitly as a disk-first middle ground when a collection is too large to keep full vectors resident safely. It is not the automatic 4-GB recommendation because measured cold latency was almost unchanged versus `low-memory` when vectors remained on disk.

The 8-GB default changed from `balanced-lite` to `balanced-memory` after cross-host tests showed substantial RAM headroom at 100K×768 while disk-backed vectors could create very high cold-query latency on some hosted filesystems.

## Dataset-aware advisor

Use the advisor when you know the expected collection size:

```bash
bash qdrant.sh profile-advisor --points 100000 --dimension 768
```

JSON output for automation:

```bash
bash qdrant.sh profile-advisor --points 100000 --dimension 768 --json
```

The advisor reports exact raw-vector footprint and a conservative working-set budgeting heuristic. It does **not** modify the running instance.

## low-memory

Target: constrained development/demo hosts, especially ~2-5.5 GB or datasets large relative to RAM.

- startup Low Memory Mode `no_populate`;
- vectors on disk;
- HNSW on disk;
- payload on disk;
- limited search/optimizer/indexing concurrency.

This minimizes resident memory but can create high cold-query latency until mmap/page-cache data becomes hot.

## balanced-lite

Disk-first middle ground:

- normal startup memory behavior;
- vectors on disk;
- payload on disk;
- HNSW in memory;
- conservative indexing/optimization concurrency.

Use this when `balanced-memory` would leave insufficient RAM headroom for the expected vector footprint.

## balanced-memory

Default for roughly 6-10 GB hosts with small/medium collections:

- normal startup memory behavior;
- vectors in memory;
- HNSW in memory;
- payload on disk;
- conservative indexing/optimization concurrency.

This profile specifically targets the measured 8-GB-host trade-off: spend a few hundred MB more RAM to avoid the very large first-query/cold-cache penalties observed with disk-backed vectors.

## balanced

Target: approximately 10-22 GB development hosts.

- vectors/HNSW favor memory;
- payload remains on disk;
- normal optimizer/search thread behavior.

## performance

Target: RAM-rich hosts and fast local storage. Vectors/HNSW/payload favor memory and Qdrant uses automatic thread selection. Benchmark before choosing it.

## Clean A/B comparison

For disposable benchmark/test instances, prefer the order-controlled helper. It performs a fresh reinstall for each profile and can reverse the order on the second cycle to reduce sequence bias:

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

`reinstall-test` is destructive and is intentionally separate from normal setup/cleanup. See [RESET-REINSTALL.md](RESET-REINSTALL.md).
