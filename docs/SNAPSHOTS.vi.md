# Snapshot và Recovery

> 🌐 Language / Ngôn ngữ: [English](SNAPSHOTS.md) | **Tiếng Việt**

Snapshot là cơ chế recovery portable của toolkit single-node này, đặc biệt quan trọng trên các platform development có runtime tạm thời.

## Collection snapshot

Dùng collection snapshot khi cần backup hoặc migrate một collection.

Tạo:

```bash
bash qdrant.sh snapshots create-collection colab_demo
```

Liệt kê:

```bash
bash qdrant.sh snapshots list-collection colab_demo
```

Download:

```bash
bash qdrant.sh snapshots download-collection \
  colab_demo SNAPSHOT_NAME /path/to/colab_demo.snapshot
```

Project tạo:

```text
/path/to/colab_demo.snapshot
/path/to/colab_demo.snapshot.sha256
```

Restore:

```bash
bash qdrant.sh snapshots restore-collection restored_demo /path/to/colab_demo.snapshot
```

Nếu file `.sha256` tồn tại thì checksum được kiểm tra trước.

## Full-storage snapshot

Full snapshot chứa trạng thái toàn bộ single-node storage, bao gồm collection alias.

Tạo:

```bash
bash qdrant.sh snapshots create-full
```

Liệt kê:

```bash
bash qdrant.sh snapshots list-full
```

Download:

```bash
bash qdrant.sh snapshots download-full SNAPSHOT_NAME /path/to/full.snapshot
```

## Full-storage restore

Qdrant restore full-storage snapshot bằng CLI lúc khởi động, không dùng REST restore thông thường.

Project bọc workflow này bằng:

```bash
bash qdrant.sh snapshots restore-full /path/to/full.snapshot --yes
```

Manager thực hiện:

1. Verify `.sha256` nếu có.
2. Stop Qdrant nếu đang chạy.
3. Move storage hiện tại vào rollback directory có timestamp.
4. Tạo storage directory mới.
5. Start Qdrant với `--storage-snapshot`.
6. Chờ authenticated readiness.
7. Sau khi thành công vẫn giữ storage cũ làm rollback copy.
8. Nếu restore startup thất bại, khôi phục storage cũ và thử restart database ban đầu.

Rollback copy nằm tại:

```text
$BASE_DIR/recovery-backups/
```

Chỉ xóa rollback cũ sau khi đã xác minh database restore hoạt động đúng.

## Đưa snapshot ra khỏi runtime ephemeral

Snapshot chỉ nằm trong runtime ephemeral có thể mất khi session bị reset/xóa. Hãy copy snapshot đã hoàn tất sang persistent storage hoặc download về máy.

Ví dụ copy sang một durable backup directory:

```bash
cp /path/to/full.snapshot /path/to/durable-backups/
cp /path/to/full.snapshot.sha256 /path/to/durable-backups/
```

Cloud/FUSE storage phù hợp để giữ bản copy snapshot đã hoàn tất, nhưng không nên dùng làm live storage directory của Qdrant.

## Khi nâng version

Trước khi test Qdrant version khác:

1. Tạo và export snapshot.
2. Ghi lại version đang chạy ổn.
3. Test version mới bằng `QDRANT_VERSION=...`.
4. Kiểm tra collection, số point, query, payload và application client.
5. Giữ snapshot cũ cho đến khi chấp nhận version mới.

Nếu dữ liệu ứng dụng quan trọng, snapshot không nên là source of truth duy nhất.

## Export backup portable

Lệnh backup cấp cao tạo snapshot mới, download tới thư mục đích rồi sinh SHA256 portable và JSON manifest:

```bash
bash qdrant.sh backup full /path/to/durable-backups
bash qdrant.sh backup collection portable_demo /path/to/durable-backups
```

Manifest ghi thời gian tạo, loại/tên snapshot, Qdrant version, resource profile và platform được phát hiện. Cách này an toàn hơn việc copy live storage directory.

Full restore hoạt động với cả service-user và current-user mode miễn current account có quyền điều khiển runtime directory/process đã cấu hình.
