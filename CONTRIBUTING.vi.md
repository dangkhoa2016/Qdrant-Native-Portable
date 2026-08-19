# Đóng góp

> 🌐 Language / Ngôn ngữ: [English](CONTRIBUTING.md) | **Tiếng Việt**

Đóng góp được hoan nghênh khi giúp Qdrant Native Portable giữ tính portable, dễ hiểu, chú trọng bảo mật và chính xác về phạm vi đã thực sự được validation.

## Nguyên tắc thiết kế

- Giữ **native-first** làm core, đồng thời tách Docker và provider adapter thành các deployment surface rõ ràng; Docker không được trở thành yêu cầu bắt buộc cho native workflow.
- Giữ nguyên hoạt động rootless `current-user + minimal`.
- Tách các giả định dành cho Colab, Kaggle, Codespaces, generic Linux, Docker và từng provider qua boundary platform/adapter rõ ràng.
- Phân biệt live database storage với persistence của snapshot đã hoàn tất; không tuyên bố storage backend của provider an toàn cho live Qdrant files khi chưa có bằng chứng.
- Không bao giờ commit credential thật, private runtime URL, snapshot chứa dữ liệu riêng tư, log, `runtime.env`, `secrets.env` hoặc token được tạo.
- Ưu tiên cấu hình qua environment variable và default ổn định, có tài liệu.
- Giữ tài liệu hướng tới người dùng bằng English và Tiếng Việt đồng bộ.
- Mức tuyên bố validation phải khớp bằng chứng: regression-tested, real-host validated và real-provider validated không thể dùng thay thế cho nhau.

## Trước khi mở pull request

Chạy canonical source check và static checks:

```bash
python3 scripts/source-integrity.py check --root . --manifest SOURCE-MANIFEST.json --require-clean
bash tests/static-checks.sh
```

Khi đã có runtime local được cấu hình, chạy thêm:

```bash
bash qdrant.sh doctor
bash qdrant.sh security-check
bash qdrant.sh health
```

Với thay đổi liên quan release packaging, source integrity hoặc public source, chạy thêm:

```bash
bash tests/test-release-package.sh
```

Với thay đổi resource profile, hãy cung cấp benchmark command có thể tái lập và thông tin host từ `bash qdrant.sh system-info`. Với thay đổi native lifecycle, PID handling, readiness hoặc service manager, chạy thêm `bash tests/test-start-readiness.sh`.

Thay đổi provider persistence phải kèm mức bằng chứng mạnh nhất thực sự có cho provider đó và phải giữ hành vi restore/corruption fail-closed ở những nơi đã được tài liệu hóa.

Không đưa API key đã reveal, provider secret, private URL hoặc dữ liệu riêng tư vào test, benchmark artifact, issue hay pull request.
