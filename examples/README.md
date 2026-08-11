# Examples

> 🌐 Language / Ngôn ngữ: **English** | [Tiếng Việt](README.vi.md)

Examples are isolated from infrastructure code and never embed an API key or live public URL.

## Prepare the environment

Find the current local endpoint and base directory:

```bash
bash qdrant.sh system-info
```

Then load credentials and choose the endpoint printed by the toolkit, for example minimal mode:

```bash
source scripts/activate.sh
```

Proxy mode normally uses:

```bash
export QDRANT_URL=http://127.0.0.1:9090
```

For a public endpoint, set `QDRANT_URL` to the URL printed by `bash qdrant.sh public`. Do not hard-code temporary URLs into source.

Optional collection override:

```bash
export QDRANT_COLLECTION=my_demo_collection
```

Each example uses the admin key only for create/upsert and the read-only key for the final query when available.

## cURL

Dependencies: `curl`, `jq`.

```bash
bash examples/curl/basic.sh
```

Best for learning the raw REST request/response format.

## Python REST

```bash
pip install -r examples/python/requirements.txt
python3 examples/python/rest_client.py
```

Uses `requests` and the Query API.

## Python SDK

```bash
python3 examples/python/sdk_client.py
```

Uses `qdrant-client` and `query_points()`. The sample keeps `prefer_grpc=False` for portability; enabling server-side gRPC is optional.

## Node.js

```bash
cd examples/node
npm install
npm start
```

Uses `@qdrant/js-client-rest` and `client.query()`. Never commit generated `node_modules/`.

## Ruby

No gem required; it uses standard-library `Net::HTTP`:

```bash
ruby examples/ruby/client.rb
```

## Run multiple examples

From project root:

```bash
bash qdrant.sh examples
```

The runner skips examples whose optional runtime/dependency is unavailable.

## Security rule for sample code

Examples are frequently copied into notebooks, tutorials, issues, screenshots, and public repositories. A real API key inside sample code is therefore considered a security defect. Use environment variables even for temporary demo instances.
