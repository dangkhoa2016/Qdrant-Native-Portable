# Đóng góp

> 🌐 Language / Ngôn ngữ: [English](CONTRIBUTING.md) | **Tiếng Việt**

Đóng góp được hoan nghênh khi giữ project portable, dễ hiểu và an toàn cho mục đích giáo dục công khai.

## Nguyên tắc thiết kế

- Giữ Docker là tùy chọn/ngoài core: repository này chứng minh Qdrant chạy native.
- Giữ nguyên hoạt động rootless `current-user + minimal`.
- Không đưa giả định về Colab/Codespaces/Kaggle vào generic core khi platform detection có thể tách biệt chúng.
- Không bao giờ commit credential thật, runtime URL, snapshot, log, `runtime.env` hoặc token được tạo.
- Ưu tiên cấu hình qua environment variable và default ổn định, có tài liệu.
- Giữ tài liệu EN/VI đồng bộ khi thay đổi workflow hiển thị cho người dùng.

## Trước khi mở pull request

```bash
bash tests/static-checks.sh
```

Khi đã có runtime local được cấu hình, chạy thêm:

```bash
bash qdrant.sh doctor
bash qdrant.sh security-check
bash qdrant.sh health
```

Đối với thay đổi resource profile, cung cấp lệnh benchmark có thể lặp lại và thông tin host liên quan từ:

```bash
bash qdrant.sh system-info
```

Đối với thay đổi native lifecycle, PID handling, readiness hoặc service manager, chạy thêm regression test tập trung qua public entry point:

```bash
bash tests/test-start-readiness.sh
```

Test này bao phủ process hiện có trở nên ready sau một khoảng trễ, process thoát sớm, enforcement của wall-clock timeout, việc ẩn lỗi curl tạm thời và precedence/persistence của cấu hình startup timeout. Khi review thay đổi lifecycle, cần đối chiếu `scripts/05_start_qdrant.sh`, public dispatch path trong `scripts/service-manager.sh` và readiness/config helper dùng chung trong `scripts/common.sh`; failure phải giữ exit status non-zero xuyên suốt `bash qdrant.sh start`.

Không đưa API key đã hiển thị hoặc dữ liệu riêng tư vào log/issue benchmark.
