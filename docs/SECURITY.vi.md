# Hướng dẫn bảo mật

> 🌐 Language / Ngôn ngữ: [English](SECURITY.md) | **Tiếng Việt**

## Threat model

Toolkit hướng tới instance single-node nhỏ hoặc có thể xóa, dùng cho development/demo. Mục tiêu là bắt buộc authentication, chỉ bind loopback mặc định, giảm rò rỉ secret, hỗ trợ least privilege và cung cấp workflow rotate/recovery rõ ràng.

Đây không phải production secret manager, VPC boundary, WAF, lớp multi-tenant isolation hay nền tảng HA.

## Tách secret khỏi runtime state

Secret:

```text
$BASE_DIR/secrets.env
```

Cấu hình vận hành không chứa secret:

```text
$BASE_DIR/runtime.env
```

Cả hai dùng mode `600`. API key không được ghi vào `qdrant.yaml`; Qdrant nhận chúng qua environment `QDRANT__SERVICE__*` lúc process khởi động.

Environment do người dùng truyền trực tiếp được ưu tiên hơn giá trị đã lưu, tránh key/config cũ âm thầm ghi đè lựa chọn mới.

## Các loại key

Setup mặc định tạo:

- admin API key;
- read-only API key;
- alternate admin key chỉ khi staged rotation đang diễn ra.

Status bình thường che key. Chỉ reveal khi thật sự cần:

```bash
bash scripts/show_credentials.sh --reveal
```

Không đưa output này vào `tee` log, screenshot, GitHub issue, notebook hoặc source code.

## Rotate key

Read-only:

```bash
bash qdrant.sh credentials rotate-readonly --restart
```

Staged admin rotation:

```bash
bash qdrant.sh credentials stage-admin-rotation --restart
# chuyển client sang alternate key
bash qdrant.sh credentials promote-admin-rotation --restart
```

Môi trường demo có thể đổi cả hai ngay:

```bash
bash qdrant.sh credentials rotate-all --restart
```

## JWT RBAC

JWT RBAC mặc định tắt. Bật chủ động:

```bash
bash qdrant.sh credentials jwt-enable --restart
```

Token read-only cho một collection:

```bash
bash qdrant.sh credentials create-token \
  --scope fairy_tales:r \
  --ttl 3600
```

Token chỉ được write một collection:

```bash
bash qdrant.sh credentials create-token \
  --scope demo_app:rw \
  --ttl 900
```

Có thể dùng nhiều `--scope`. `--access r` và `--access m` là quyền global nâng cao.

Helper ký HS256 JWT bằng admin API key của Qdrant và lưu token dưới `$BASE_DIR/tokens/` với mode `600`. Vì vậy rotate/promote admin key sẽ làm JWT ký bằng key cũ mất hiệu lực; cần phát hành token mới sau khi rotate.

JWT RBAC hữu ích để scope demo/service, nhưng không nên giao admin API key cho code không đáng tin chỉ để code đó tự mint token.

## Strict Mode

`QDRANT_STRICT_MODE=1` mặc định áp dụng cho collection mới. Generated defaults giới hạn một số query tốn tài nguyên như result limit, timeout, HNSW `ef`, exact search, oversampling và unindexed filtering theo `.env.example`.

Strict Mode là resource guardrail, không thay thế authentication, authorization, rate limiting hay network control.

## Network mode

Qdrant REST mặc định bind:

```text
127.0.0.1:6333
```

Proxy mode dùng Nginx loopback:

```text
127.0.0.1:9090
```

Public access luôn là opt-in. `bash qdrant.sh start` không public database.

Trên GitHub Codespaces, `PUBLIC_MODE=platform` đổi forwarded port sang public. `bash qdrant.sh public-stop` cố đưa port trở lại private.

Cloudflare Quick Tunnel chỉ là ingress development/testing, không phải production endpoint cố định.

## TLS và CORS

Loopback local dùng HTTP. Remote access nên terminate TLS ở platform/tunnel/reverse proxy. Không gửi API key qua plaintext network không đáng tin.

CORS mặc định tắt. Chỉ bật khi browser ở origin khác thật sự cần gọi Qdrant trực tiếp:

```bash
ENABLE_CORS=true bash qdrant.sh setup
```

Backend-to-Qdrant không cần browser CORS.

## Request size và public demo

`QDRANT_MAX_REQUEST_SIZE_MB` điều khiển request limit của Qdrant và, ở proxy mode, Nginx body limit tương ứng. Nên giữ thấp vừa phải khi public demo.

Nếu cần bảo vệ mạnh hơn, thêm ingress rate limiting/authentication phía trước. Project không coi API key + Strict Mode là một production Internet security perimeter hoàn chỉnh.

## Rootless và service-user

`current-user` không cần root và portable hơn, nhưng không tạo thêm ranh giới OS account riêng cho Qdrant.

`service-user` chạy Qdrant bằng non-login user riêng và cần root. Dùng khi OS-level isolation có giá trị và platform cho phép.

## Security checks

Kiểm tra repository:

```bash
bash tests/static-checks.sh
```

Kiểm tra runtime đã cấu hình:

```bash
bash qdrant.sh security-check
bash qdrant.sh doctor
```

Luôn kiểm tra staged changes trước khi public push.

## Nếu credential bị lộ

1. Coi key/token đã lộ là compromised.
2. Rotate API key tương ứng.
3. Restart Qdrant khi environment API key thay đổi.
4. Phát hành lại JWT nếu admin signing key thay đổi.
5. Cập nhật client.
6. Nếu secret đã commit, xóa khỏi Git history; chỉ delete ở commit sau là chưa đủ.
7. Kiểm tra log, notebook, screenshot, release archive và code mẫu đã paste.

## Guardrail tài nguyên cho public/demo

Strict Mode mặc định có giới hạn query/timeout/HNSW và thêm hai guardrail của Qdrant 1.18 hữu ích trên host hạn chế tài nguyên:

```text
QDRANT_STRICT_MAX_RESIDENT_MEMORY_PERCENT=85
QDRANT_STRICT_SEARCH_MAX_BATCHSIZE=64
```

Giá trị đầu có thể từ chối write tốn RAM khi resident memory của Qdrant vượt tỷ lệ RAM hệ thống đã cấu hình; giá trị thứ hai giới hạn batch-search size. Hãy tune theo workload thay vì tắt authentication hoặc resource protection.
