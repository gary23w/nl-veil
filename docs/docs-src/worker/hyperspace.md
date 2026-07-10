# hyperspace

**File:** `src/worker/hyperspace.zig`  
**Module:** `worker`  
**Description:** Vector embedding and similarity-search engine: wraps embedding models, maintains an in-memory vector index, and supports nearest-neighbor queries.

---

## Purpose Summary

Vector embedding and similarity-search engine: wraps embedding models, maintains an in-memory vector index, and supports nearest-neighbor queries.

## Key Exports

- `Hyperspace` struct — vector index
- `embed(text)` — produce embedding vector
- `search(query, k)` — k-nearest-neighbor
- `index_size()` — number of stored vectors

## Dependencies

- `worker/commons` — config types
- Standard library: math, collections (vector storage)

## Usage Context

Used by AGI worker for memory retrieval, and by chat_tools for semantic search.

## Notable Implementation Details

Embeds are computed locally via ONNX runtime for small models, or proxied to an external API for large models. Index uses HNSW (Hierarchical Navigable Small World) for approximate nearest neighbor.

---

*Documentation generated for nl-veil — hyperspace.zig source analysis.*
