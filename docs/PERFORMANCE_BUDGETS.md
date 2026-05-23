# Performance Budgets

Default budgets target repeatable SwiftPM/Catalyst runs. Set `LUMINA_STRICT_PERF=1` to turn strict thresholds on.

| Area | Budget |
| --- | ---: |
| `runStream` first event | < 50 ms strict |
| Mock ReAct + read-only tool p95 | < 180 ms strict |
| Cancellation after planner/tool wait | < 100 ms strict |
| Memory search, 1k chunks | < 250 ms strict |
| Memory search, 10k chunks | < 750 ms strict |
| Memory search, 50k metadata-filtered | < 1000 ms strict, heavy only |
| Cache hit | < 50 ms strict |
| Ingest 1k docs without waiting for embedding | < 500 ms strict |
| Markdown large parse | < 800 ms strict |
| Markdown cache hit | < 20 ms strict |

Commands:

```bash
swift test
swift test --filter PerformanceTests
LUMINA_RUN_HEAVY_BENCHMARKS=1 swift test --filter PerformanceTests
LUMINA_STRICT_PERF=1 swift test --filter PerformanceTests
./scripts/perf.sh
```

Core ML model benchmarks are optional:

```bash
LUMINA_EMBEDDING_MODEL=/abs/BGETextEmbedding.mlmodelc \
LUMINA_GEMMA4_PLANNER_MODEL=/abs/Gemma4Planner.mlmodelc \
LUMINA_RUN_MODEL_BENCHMARKS=1 \
swift test --filter PerformanceTests
```
