# Code mẫu

> 🌐 Language / Ngôn ngữ: [English](README.md) | **Tiếng Việt**

Code mẫu được tách khỏi infrastructure code và không bao giờ hard-code API key hoặc public URL đang hoạt động.

## Chuẩn bị environment

Xem endpoint và base directory hiện tại:

```bash
bash qdrant.sh system-info
```

Load credential và chọn endpoint do toolkit in ra, ví dụ minimal mode:

```bash
source scripts/activate.sh
```

Proxy mode thường dùng:

```bash
export QDRANT_URL=http://127.0.0.1:9090
```

Nếu dùng public endpoint, đặt `QDRANT_URL` thành URL do `bash qdrant.sh public` in ra. Không hard-code URL tạm thời vào source.

Có thể đổi collection:

```bash
export QDRANT_COLLECTION=my_demo_collection
```

Mỗi ví dụ chỉ dùng admin key cho create/upsert và ưu tiên read-only key cho query cuối.

## cURL

Dependency: `curl`, `jq`.

```bash
bash examples/curl/basic.sh
```

Phù hợp nhất để học request/response REST thô.

## Python REST

```bash
pip install -r examples/python/requirements.txt
python3 examples/python/rest_client.py
```

Dùng `requests` và Query API.

## Python SDK

```bash
python3 examples/python/sdk_client.py
```

Dùng `qdrant-client` và `query_points()`. Code mẫu giữ `prefer_grpc=False` để portable; server-side gRPC có thể bật riêng.

## Node.js

```bash
cd examples/node
npm install
npm start
```

Dùng `@qdrant/js-client-rest` và `client.query()`. Không commit `node_modules/`.

## Ruby

Không cần gem; dùng `Net::HTTP` trong standard library:

```bash
ruby examples/ruby/client.rb
```

## Chạy nhiều ví dụ

Từ project root:

```bash
bash qdrant.sh examples
```

Runner tự bỏ qua ví dụ thiếu runtime/dependency tùy chọn.

## Quy tắc bảo mật cho sample code

Code mẫu thường bị copy sang notebook, tutorial, issue, screenshot và public repository. Vì vậy API key thật trong sample code được coi là lỗi bảo mật. Luôn dùng environment variables kể cả instance demo tạm thời.
