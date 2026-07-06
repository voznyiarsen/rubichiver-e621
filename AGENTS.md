# rubichiver-e621 — Agent Quick-Start

## System Overview
A Ruby CLI tool that downloads media from e621.net, fetches post metadata via the e621 v2 JSON API (paginated, 320 per page), keeps files in original format, and writes XMP sidecar files (.xmp) with IPTC:Keywords + XMP:Rating. Runs as a one-shot batch job reading tag queries from a file.

## Tech Stack
- **Language:** Ruby 3.x (no gems beyond stdlib)
- **External Tools:** ExifTool (XMP sidecar writing)
- **API:** e621.net v2 JSON API (`/posts.json` with `v2=true&mode=extended`)

## Environment & Configuration
| File | Purpose | Format |
|------|---------|--------|
| `api_credentials.txt` | API auth | `USERNAME=...` / `API_KEY=...` (one per line) |
| `tags.txt` | Tag queries | One whitespace-separated query per line |
| `blacklist.txt` | Blacklist rules | e621 blacklist syntax (`~OR`, `-negation`, `rating:`) |

Required system deps: `exiftool`.

## Directory Structure
```
rubichiver-e621/
├── rubichiver-e621.rb   # Main script (entry point)
├── blacklist.rb          # Blacklist parser
├── logger.rb             # Structured logging (JSON + human)
├── post_processor.rb     # Worker pool (download + XMP sidecar)
├── rate_limiter.rb       # Thread-safe API rate limiter
├── Gemfile               # Ruby dependencies (none required beyond stdlib)
├── api_credentials.txt   # API credentials (gitignored)
├── tags.txt              # Tag queries (gitignored)
├── blacklist.txt         # Blacklist rules (gitignored)
└── e6archive/            # Default output directory (created at runtime)
    └── cache/            # API response cache (JSON files, persistent across runs)
```

## Dependencies & Services
- **e621.net API** — Rate limited (1 req/sec enforced via `RateLimiter`)
- **ExifTool** — Called directly via `Open3` for XMP sidecar writing

## How to Run
```bash
# Run (uses defaults: ./tags.txt, ./api_credentials.txt, ./e6archive)
ruby rubichiver-e621.rb

# Common options
ruby rubichiver-e621.rb -o ./custom_output -t ./my_tags.txt -c ./my_creds.txt -v
ruby rubichiver-e621.rb --dry-run        # Show what would be done
ruby rubichiver-e621.rb -j 4             # Worker threads (default: 2)
ruby rubichiver-e621.rb --rate-limit 2   # API requests per second (default: 1)
```

## Key Conventions
- **Post discovery** — For each line in `tags.txt`, fetches matching posts from e621 v2 API (`/posts.json?tags=...&page=N&limit=320&v2=true&mode=extended`) with file-based JSON caching in `$output_dir/cache/`.
- **Deduplication** — At startup, scans output directory once into `$existing_posts` hash map (post\_id → file\_path) for O(1) lookups; per-run dedup via `Set` of seen IDs across queries.
- **Existing file handling** — If found on disk without XMP sidecar, writes sidecar. If sidecar exists, skips entirely.
- **Parallelism** — Worker thread pool runs download + XMP sidecar. Default 2 threads.
- **Interrupt handling** — First Ctrl+C sets `$interrupted` flag to finish in-progress work; second Ctrl+C force-exits.
- **Rate limiting** — `RateLimiter` class with configurable requests/sec; applied to all API calls (search + download).
- **No transcoding** — Media kept in original format (webm, avi, mov, etc.). Only XMP sidecars are written.
- **XMP sidecars** — ExifTool writes `.xmp` files with `XMP:Rating` (1-3) and `IPTC:Keywords` (`rating:label`, `category:tag` entries).
- **Blacklist** — e621 blacklist syntax: `~OR` groups, `-negation`, `rating:`, `id:`. Applied before enqueueing.
- **Unsupported formats** — SWF files skipped entirely.
- **Error handling** — Retries with exponential backoff (3 attempts) on download; failures logged but don't halt batch.
