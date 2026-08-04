# Chính sách bảo mật

> 🌐 Language / Ngôn ngữ: [English](SECURITY.md) | **Tiếng Việt**

## Báo cáo lỗ hổng

Vui lòng không công khai credential, chi tiết exploit hoặc log runtime nhạy cảm trong issue công khai. Nếu tab Security của repository có chức năng **Report a vulnerability**, hãy dùng luồng báo cáo riêng đó. Nếu chức năng chưa được bật, chỉ mở issue không chứa thông tin nhạy cảm và yêu cầu maintainer cung cấp kênh liên hệ riêng; không đưa chi tiết exploit hay secret vào issue đó.

## Chính sách secret

Repository này không bao giờ được chứa:

- API key Qdrant thật;
- URL tunnel tạm thời từ session đang chạy;
- `secrets.env` từ runtime;
- log chứa credential đã hiển thị;
- bản sao database tải xuống chứa dữ liệu riêng tư.

Chạy `bash tests/static-checks.sh` trước khi publish thay đổi.

Hướng dẫn bảo mật khi deployment, xem [docs/SECURITY.md](docs/SECURITY.md) và [docs/SECURITY.vi.md](docs/SECURITY.vi.md).
