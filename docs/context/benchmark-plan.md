# Engram Retrieval Benchmark Plan

How to benchmark embedding models, chunking strategies, rerankers, and vector DBs
to make informed SaaS architecture decisions.

## Why This Matters

Every open decision (D2-D5) in the SaaS migration plan is blocked on benchmark data.
The choices directly affect: per-user cost, Qdrant free tier runway, search latency,
and search quality. We need numbers, not guesses.

---

## 1. Ground Truth Dataset

Before benchmarking anything, we need a labeled test set.

### What to Build

A JSON file of 50-100 test queries, each with expected results ranked by relevance.

```json
{
  "queries": [
    {
      "query": "how do I configure DHCP static leases",
      "relevant_notes": [
        {"path": "2. Knowledge Vault/.../DHCP KEA.md", "relevance": 3},
        {"path": "2. Knowledge Vault/.../Network Carving.md", "relevance": 2},
        {"path": "2. Knowledge Vault/.../Patch Panel.md", "relevance": 1}
      ],
      "tags_filter": null,
      "folder_filter": null
    }
  ]
}
```

Relevance scale:
- 3 = perfect match (this is THE note you'd want)
- 2 = highly relevant (useful context)
- 1 = tangentially related

### How to Build It

1. Export 20-30 diverse notes from your vault (short, long, technical, personal)
2. For each, write 2-3 natural queries someone might ask to find it
3. For each query, rank which notes should appear in top 5
4. Include edge cases:
   - Queries that use different words than the note (semantic gap)
   - Queries that match multiple notes (disambiguation)
   - Queries with tag/folder filters
   - Very short queries ("docker networking")
   - Natural language queries ("what supplements do I take")

### File Location

```
benchmarks/
  ground_truth.json          # The labeled test set
  vault_snapshot/            # Frozen copy of test notes (reproducibility)
```

### Tips

- Use your actual vault, not synthetic data — this tests real-world retrieval
- Don't over-engineer: 50 solid queries > 200 sloppy ones
- Include queries where current search fails — that's what we're trying to improve
- Revisit and expand over time

---

## 2. Benchmark Harness

A Python script that: indexes notes → runs queries → measures quality metrics.

### Architecture

```
benchmarks/
  ground_truth.json
  vault_snapshot/
  run_benchmark.py           # Main harness
  configs/                   # Benchmark configurations
    baseline.yaml            # Current setup (nomic-embed-text, 512 chunk, Jina)
    openai_small_512d.yaml   # text-embedding-3-small at 512d
    openai_small_256d.yaml   # text-embedding-3-small at 256d
    minilm_384d.yaml         # all-MiniLM-L6-v2
    no_reranker.yaml         # Vector-only search
    bm25_hybrid.yaml         # BM25 + vector fusion
    whole_note.yaml          # No chunking
    chunk_256.yaml           # 256 token chunks
    chunk_1024.yaml          # 1024 token chunks
  results/                   # Benchmark outputs (gitignored)
    baseline_2026-03-30.json
    openai_small_512d_2026-03-30.json
```

### Config Format

```yaml
name: "OpenAI text-embedding-3-small @ 512d"
embedding:
  provider: openai           # ollama | openai | local
  model: text-embedding-3-small
  dimensions: 512
chunking:
  strategy: heading_aware    # heading_aware | whole_note | adaptive
  max_tokens: 512
  overlap_tokens: 50
  contextual_prefix: false   # prepend "From note X, section Y:" before embedding
reranker:
  enabled: true              # true | false
  provider: jina             # jina | cohere | none
  weight: 0.6                # blending weight (0 = vector only, 1 = rerank only)
vector_db:
  provider: qdrant           # qdrant | pgvector
```

### Harness Flow

```
1. Load ground_truth.json
2. Load config
3. Index vault_snapshot/ with config's embedding + chunking settings
4. For each query:
   a. Embed query
   b. Search (vector DB + optional reranker)
   c. Compare results to ground truth
   d. Record: latency, results, scores
5. Calculate aggregate metrics
6. Save results JSON
```

### Implementation Sketch

```python
# benchmarks/run_benchmark.py

import json, yaml, time
from pathlib import Path

def load_ground_truth(path: str) -> dict:
    return json.loads(Path(path).read_text())

def load_config(path: str) -> dict:
    return yaml.safe_load(Path(path).read_text())

def index_vault(config: dict, vault_path: str) -> tuple[float, int]:
    """Index all notes in vault_snapshot. Returns (duration_secs, chunk_count)."""
    # Use engram's existing parse_markdown_content + embedder + qdrant_store
    # Swap embedder/chunker based on config
    ...

def search(query: str, config: dict, limit: int = 10) -> list[dict]:
    """Run search pipeline. Returns ranked results with scores and latency."""
    start = time.perf_counter()
    # Embed query with config's embedder
    # Search with config's vector_db
    # Optionally rerank
    elapsed = time.perf_counter() - start
    return {"results": [...], "latency_ms": elapsed * 1000}

def evaluate(results: list[dict], expected: list[dict]) -> dict:
    """Calculate retrieval metrics."""
    return {
        "recall_at_5": recall_at_k(results, expected, k=5),
        "recall_at_10": recall_at_k(results, expected, k=10),
        "mrr": mean_reciprocal_rank(results, expected),
        "ndcg_at_5": ndcg_at_k(results, expected, k=5),
    }

def run_benchmark(config_path: str, ground_truth_path: str):
    config = load_config(config_path)
    gt = load_ground_truth(ground_truth_path)

    # Index
    index_time, chunk_count = index_vault(config, "benchmarks/vault_snapshot")

    # Search + evaluate each query
    all_results = []
    for entry in gt["queries"]:
        search_result = search(entry["query"], config)
        metrics = evaluate(search_result["results"], entry["relevant_notes"])
        all_results.append({
            "query": entry["query"],
            "latency_ms": search_result["latency_ms"],
            **metrics
        })

    # Aggregate
    summary = {
        "config": config["name"],
        "index_time_secs": index_time,
        "chunk_count": chunk_count,
        "avg_recall_at_5": mean([r["recall_at_5"] for r in all_results]),
        "avg_recall_at_10": mean([r["recall_at_10"] for r in all_results]),
        "avg_mrr": mean([r["mrr"] for r in all_results]),
        "avg_ndcg_at_5": mean([r["ndcg_at_5"] for r in all_results]),
        "p50_latency_ms": percentile([r["latency_ms"] for r in all_results], 50),
        "p95_latency_ms": percentile([r["latency_ms"] for r in all_results], 95),
        "per_query": all_results
    }

    # Save
    out = f"benchmarks/results/{config['name']}_{date.today()}.json"
    Path(out).write_text(json.dumps(summary, indent=2))
    return summary
```

---

## 3. Metrics Explained

| Metric | What It Measures | Why It Matters |
|--------|-----------------|----------------|
| **Recall@K** | % of relevant notes found in top K results | "Did we find the right notes?" |
| **MRR** | How high the first relevant result ranks (1/rank) | "How quickly do users see what they need?" |
| **nDCG@K** | Ranking quality weighted by relevance grade | "Are the best results at the top?" |
| **p50 Latency** | Median search time | User experience for typical searches |
| **p95 Latency** | Worst-case search time (1 in 20) | User experience for slow searches |
| **Index Time** | Time to embed + store all notes | Onboarding speed for new users |
| **Chunk Count** | How many vectors per note | Qdrant storage cost driver |

### What "Good" Looks Like

```
  Metric       │ Acceptable │ Good    │ Excellent
  ─────────────┼────────────┼─────────┼──────────
  Recall@5     │ > 0.60     │ > 0.75  │ > 0.85
  Recall@10    │ > 0.75     │ > 0.85  │ > 0.95
  MRR          │ > 0.40     │ > 0.55  │ > 0.70
  nDCG@5       │ > 0.50     │ > 0.65  │ > 0.80
  p50 Latency  │ < 500ms    │ < 300ms │ < 150ms
  p95 Latency  │ < 1000ms   │ < 500ms │ < 300ms
```

---

## 4. Benchmark Runs (Priority Order)

### Run 1: Establish Baseline

```
  Config: current setup (nomic-embed-text 768d, 512/50 chunks, Jina reranker)
  Purpose: know where we stand before changing anything
  Infrastructure: run against local Qdrant + Ollama on FastRaid
```

### Run 2: Reranker Impact (answers D4)

```
  Configs to compare:
  a. Baseline (with Jina, 60% weight)          ← current
  b. Vector-only (no reranker)                  ← simplest
  c. Jina at 40% weight                         ← less reranker influence
  d. BM25 hybrid (keyword + vector, no reranker)← free alternative

  Key question: does the reranker add enough quality to justify
  the latency + cost + service dependency?

  If (a) - (b) < 5% recall difference → drop the reranker.
```

### Run 3: Embedding Models (answers D2)

```
  Configs to compare (all with same chunking, same reranker decision from Run 2):
  a. nomic-embed-text 768d (Ollama, current)     ← baseline
  b. text-embedding-3-small 768d (OpenAI API)     ← same dims, API
  c. text-embedding-3-small 512d (OpenAI API)     ← reduced dims
  d. text-embedding-3-small 256d (OpenAI API)     ← min dims
  e. all-MiniLM-L6-v2 384d (local CPU)            ← fastest local
  f. BGE-small-en-v1.5 384d (local CPU)           ← best small local
  g. gte-small 384d (local CPU)                    ← alternative small

  Measure for each: quality metrics + latency + cost/query

  Decision matrix:
  - If 384d local model is within 5% of 768d quality → huge cost win
  - If OpenAI 256d matches 768d quality → 3x Qdrant free tier extension
  - If OpenAI 512d is best quality/cost → that's the SaaS default
```

### Run 4: Chunking Strategy (answers D5)

```
  First: measure chunk distribution on vault_snapshot
  - What % of notes are single-chunk at 512 tokens?
  - Average chunks per note?
  - Distribution histogram

  Then compare (using best embedding from Run 3):
  a. 512 tokens / 50 overlap / heading-aware      ← current
  b. Whole-note embedding (no chunking)            ← simplest
  c. Adaptive (whole if <512 tok, chunk if longer) ← hybrid
  d. 256 tokens / 25 overlap                       ← smaller chunks
  e. 1024 tokens / 100 overlap                     ← larger chunks
  f. Current + contextual prefix                   ← "From note X, section Y:"

  Key question: does chunking meaningfully help for personal notes?
  If most notes are <512 tokens, whole-note may be simpler and equivalent.
```

### Run 5: pgvector vs Qdrant (answers D3 fallback)

```
  Using best embedding + chunking from Runs 3-4:
  a. Qdrant (current)
  b. pgvector with HNSW index (in local Postgres, simulating Neon)

  Measure at different scales:
  - 1,000 vectors (tiny vault)
  - 10,000 vectors (typical user)
  - 100,000 vectors (power user / multi-user)
  - 1,000,000 vectors (500+ users on SaaS)

  If pgvector is within 2x latency of Qdrant at 1M vectors → viable fallback
  to eliminate Qdrant dependency if cost becomes an issue.
```

---

## 5. Comparison Report Template

After all runs, produce a summary table:

```
  ┌──────────────────────────┬──────────┬──────────┬────────┬─────────┬──────────┬──────────┐
  │ Config                   │ Recall@5 │ Recall@10│ MRR    │ p50 lat │ p95 lat  │ $/query  │
  ├──────────────────────────┼──────────┼──────────┼────────┼─────────┼──────────┼──────────┤
  │ Baseline (current)       │          │          │        │         │          │ $0       │
  │ No reranker              │          │          │        │         │          │ $0       │
  │ BM25 hybrid              │          │          │        │         │          │ $0       │
  │ OpenAI 3-small 512d      │          │          │        │         │          │ ~$0.0001 │
  │ OpenAI 3-small 256d      │          │          │        │         │          │ ~$0.0001 │
  │ MiniLM 384d (CPU)        │          │          │        │         │          │ $0       │
  │ Whole-note embedding     │          │          │        │         │          │ varies   │
  │ Adaptive chunking        │          │          │        │         │          │ varies   │
  │ Contextual prefix        │          │          │        │         │          │ varies   │
  │ pgvector (1M vectors)    │          │          │        │         │          │ $0       │
  └──────────────────────────┴──────────┴──────────┴────────┴─────────┴──────────┴──────────┘

  WINNER: [config name]
  RATIONALE: [why this is the best quality/cost/latency trade-off for SaaS]
```

---

## 6. Infrastructure Needed

All benchmarks can run on FastRaid (current hardware):

| Run | What's Needed | Already Have? |
|-----|--------------|---------------|
| Run 1 (baseline) | Ollama + Qdrant + Jina | Yes |
| Run 2 (reranker) | Same + ability to disable reranker | Yes (config flag) |
| Run 3 (embeddings) | Ollama + OpenAI API key + sentence-transformers | Need OpenAI key, need sentence-transformers |
| Run 4 (chunking) | Same as Run 3 | Yes |
| Run 5 (pgvector) | PostgreSQL with pgvector extension | Need to install pgvector |

### Dependencies to Install

```bash
# For local CPU models (sentence-transformers)
pip install sentence-transformers torch

# For pgvector benchmarks
# In Docker: use pgvector/pgvector:pg16 image
# Or install extension: CREATE EXTENSION vector;

# For BM25 hybrid search
pip install rank_bm25

# For metrics
pip install numpy
```

### OpenAI API Key

Needed for text-embedding-3-small benchmarks. Cost estimate for full benchmark suite:
~10,000 embeddings × 500 tokens avg = 5M tokens = **$0.10 total**.

---

## 7. Decision Framework

After benchmarks, use this to make final calls:

### D2 (Embedding Model): Pick the model where...
- Recall@5 is within 5% of the best model
- Cost is sustainable at 1,000 users (20k queries/day)
- Latency p95 < 500ms
- Prefer smaller dimensions (cheaper Qdrant, faster search)

### D3 (pgvector fallback): Switch to pgvector if...
- Latency at 1M vectors is < 100ms (p95)
- Recall matches Qdrant (HNSW should be equivalent)
- Eliminates ~$50-150/mo at scale

### D4 (Reranker): Drop the reranker if...
- Quality delta < 5% recall vs vector-only
- OR BM25 hybrid matches reranker quality (free alternative)
- Saves 100-300ms latency AND a service dependency

### D5 (Chunking): Simplify chunking if...
- >80% of notes are single-chunk (chunking adds no value for most)
- Whole-note embedding recall is within 5% of chunked
- Adaptive approach handles both short and long notes

---

## 8. Timeline Estimate

```
  Step                          │ Effort    │ Depends On
  ──────────────────────────────┼───────────┼────────────
  Build ground truth dataset    │ 2-3 hours │ Nothing (manual work)
  Build benchmark harness       │ 4-6 hours │ Ground truth
  Run 1: Baseline               │ 30 min    │ Harness
  Run 2: Reranker impact        │ 1 hour    │ Harness
  Run 3: Embedding models       │ 2-3 hours │ Harness + OpenAI key
  Run 4: Chunking strategies    │ 1-2 hours │ Best embedding from Run 3
  Run 5: pgvector comparison    │ 1-2 hours │ Best config from Runs 2-4
  Analysis + decision report    │ 1-2 hours │ All runs complete
  ──────────────────────────────┼───────────┼────────────
  TOTAL                         │ ~2-3 days │
```

---

## Related

- SaaS migration plan: `.claude/plans/flickering-watching-clover.md`
- Current search pipeline: `lib/engram/search.ex`
- Current chunking: `lib/engram/parsers/markdown.ex`
- Current embedders: `lib/engram/embedders/ollama.ex`, `lib/engram/embedders/voyage.ex`
- Test suite: `mix test`
