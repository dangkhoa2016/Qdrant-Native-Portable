# Hỗ trợ

> 🌐 Language / Ngôn ngữ: [English](SUPPORT.md) | **Tiếng Việt**

Qdrant Native Portable được duy trì như một runtime/deployment toolkit Qdrant single-node mã nguồn mở. Hỗ trợ được cung cấp theo khả năng và được tổ chức qua GitHub Issues.

## Nên hỏi ở đâu

Dùng các issue form của repository cho bug có thể tái hiện, feature proposal tập trung và câu hỏi sử dụng chưa được tài liệu giải đáp. Trước khi mở issue, hãy xem [`../README.vi.md`](../README.vi.md), [`../docs/README.vi.md`](../docs/README.vi.md), [`../docs/FEATURES.vi.md`](../docs/FEATURES.vi.md), [`../docs/PLATFORMS.vi.md`](../docs/PLATFORMS.vi.md) và các issue hiện có.

Với lỗi runtime, hãy cung cấp release/commit của project, Qdrant version, runtime mode, platform, resource profile, command liên quan, hành vi mong đợi, hành vi thực tế và log đã sanitize. Không gửi API key, JWT, provider credential, private URL, snapshot chứa dữ liệu riêng tư, `secrets.env`, token file hoặc sensitive runtime state khác.

## Phạm vi

Project nhắm tới Qdrant single-node cho development, demo, integration test, benchmark và deployment theo hướng production khi các giới hạn single-node đã tài liệu hóa là phù hợp. Đây không phải managed hosting service và không cam kết HA, replication, automatic failover, multi-writer autoscaling hoặc compatibility với mọi tổ hợp Qdrant/provider chưa validation.

## Security

Không dùng public support issue để báo vulnerability nghi ngờ hoặc secret vô tình bị lộ. Hãy làm theo [`../SECURITY.vi.md`](../SECURITY.vi.md).
