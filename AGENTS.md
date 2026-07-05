# e621archiver — Agent Quick-Start

## System Overview
A Ruby CLI tool that downloads media from e621.net, fetches post metadata via the e621 JSON API (paginated, 320 per page), transcodes non-MP4 videos to MP4 (with NVIDIA GPU acceleration), and embeds XMP metadata (tags by category + rating) into the files. Runs as a one-shot batch job reading tag queries from a file.

## Tech Stack
- **Language:** Ruby 3.x (no gems beyond stdlib)
- **External Tools:** `ffmpeg` (video transcoding), `nvidia-smi` (GPU detection), ExifTool (XMP writing)
- **API:** e621.net JSON API (`/posts.json` with tag search params)

## Environment & Configuration
| File | Purpose | Format |
|------|---------|--------|
| `api_credentials.txt` | API auth | `USERNAME=...` / `API_KEY=...` (one per line) |
| `tags.txt` | Tag queries | One whitespace-separated query per line |
| `blacklist.txt` | Blacklist rules | e621 blacklist syntax (`~OR`, `-negation`, `rating:`) |

Required system deps: `ffmpeg`, `exiftool`, NVIDIA drivers + CUDA (optional, for GPU transcoding).

## Directory Structure
```
e621archiver/
├── e621archiver.rb      # Main script (entry point)
├── blacklist.rb          # Blacklist parser
├── logger.rb             # Structured logging (JSON + human)
├── post_processor.rb     # Worker pool (download/transcode/tag)
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
- **FFmpeg** — Must be in PATH; uses `h264_nvenc` if NVIDIA GPU detected, else `libx264`
- **ExifTool** — Called directly via `Open3` for XMP writing

## How to Run
```bash
# Run (uses defaults: ./tags.txt, ./api_credentials.txt, ./e6archive)
ruby e621archiver.rb

# Common options
ruby e621archiver.rb -o ./custom_output -t ./my_tags.txt -c ./my_creds.txt -v
ruby e621archiver.rb --dry-run        # Show what would be done
ruby e621archiver.rb -j 4             # Worker threads (default: 2)
ruby e621archiver.rb --rate-limit 2   # API requests per second (default: 1)
```

## Key Conventions
- **Post discovery** — For each line in `tags.txt`, fetches matching posts from e621 API (`/posts.json?tags=...&page=N&limit=320`) with file-based JSON caching in `$output_dir/cache/`.
- **Deduplication** — At startup, scans output directory once into `$existing_posts` hash map (post\_id → file\_path) for O(1) lookups; per-run dedup via `Set` of seen IDs across queries.
- **Existing file handling** — If found on disk without XMP tags, non-MP4 videos are transcoded first, then XMP is added. MP4/images get XMP directly.
- **Parallelism** — Worker thread pool runs download/transcode/tag; transcode mutex removed (parallel ffmpeg). Default 2 threads.
- **Interrupt handling** — First Ctrl+C sets `$interrupted` flag to finish in-progress work; second Ctrl+C force-exits.
- **Rate limiting** — `RateLimiter` class with configurable requests/sec; applied to all API calls (search + download).
- **Transcoding** — Non-MP4 videos (webm, avi, mov, mkv, flv, wmv) transcoded to MP4 via ffmpeg; original deleted on success.
- **XMP metadata** — ExifTool sets `XMP:Rating` (1-3) and `XMP:Subject` entries (`category:tag`, `rating:label`).
- **Blacklist** — e621 blacklist syntax: `~OR` groups, `-negation`, `rating:`, `id:`. Applied before enqueueing.
- **Unsupported formats** — SWF files skipped entirely.
- **Error handling** — Retries with exponential backoff (3 attempts) on download; failures logged but don't halt batch.
