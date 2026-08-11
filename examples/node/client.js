'use strict';

const { QdrantClient } = require('@qdrant/js-client-rest');

const url = (process.env.QDRANT_URL || 'http://127.0.0.1:9090').replace(/\/$/, '');
const adminKey = process.env.QDRANT_API_KEY || '';
const readOnlyKey = process.env.QDRANT_READ_ONLY_API_KEY || adminKey;
const collectionName = process.env.QDRANT_COLLECTION || 'node_demo';

if (!adminKey) {
  throw new Error('Set QDRANT_API_KEY before running this example');
}

const admin = new QdrantClient({ url, apiKey: adminKey });
const reader = new QdrantClient({ url, apiKey: readOnlyKey });

async function main() {
  console.log(`[node] Endpoint: ${url}`);
  console.log(`[node] Collection: ${collectionName}`);

  const collections = await admin.getCollections();
  const exists = collections.collections.some((collection) => collection.name === collectionName);
  if (!exists) {
    await admin.createCollection(collectionName, {
      vectors: { size: 4, distance: 'Cosine' },
    });
  }

  await admin.upsert(collectionName, {
    wait: true,
    points: [
      { id: 1, vector: [0.9, 0.1, 0.1, 0.1], payload: { name: 'red' } },
      { id: 2, vector: [0.1, 0.9, 0.1, 0.1], payload: { name: 'green' } },
      { id: 3, vector: [0.1, 0.1, 0.9, 0.1], payload: { name: 'blue' } },
    ],
  });

  const result = await reader.query(collectionName, {
    query: [0.8, 0.2, 0.1, 0.1],
    limit: 3,
    with_payload: true,
  });
  console.dir(result, { depth: null });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
