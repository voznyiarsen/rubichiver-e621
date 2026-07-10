# rubichiver — Unified Booru Media Archiver

## System Overview
A Ruby CLI tool that downloads media from e621.net and Gelbooru, fetches post metadata via their respective JSON APIs, keeps files in original format, and writes XMP sidecar files (.xmp) with categorized keywords + rating. Runs as a one-shot batch job reading tag queries from a file. Unified from separate `rubichiver-e621` and `rubichiver-gelbooru` gems.

## Tech Stack
- **Language:** Ruby 3.x (stdlib only, no runtime gems)
- **External Tools:** ExifTool (XMP sidecar writing)
- **APIs:**
  - e621.net v2 JSON API (`/posts.json?page=N&limit=320&v2=true&mode=extended`) — rate limited 1 req/s
  - Gelbooru API (`/index.php?page=dapi&s=post&q=index&pid=N&limit=100&json=1`) — rate limited 1 req/s

## Directory Structure
```
rubichiver/
├── rubichiver.rb          # Unified entry point (--site e621|gelbooru)
├── archiver_base.rb        # Base Archiver class with shared logic
├── archiver_e621.rb        # e621-specific API/search/download/sidecar
├── archiver_gelbooru.rb    # Gelbooru-specific API/search/download/sidecar
├── blacklist.rb            # Blacklist parser (e621 syntax)
├── logger.rb               # Structured logging (JSON + human)
├── post_processor.rb       # Worker pool + Stats
├── rate_limiter.rb         # Thread-safe API rate limiter
├── Gemfile                 # (no runtime deps)
├── e621-api-credentials.txt     # e621: USERNAME= / API_KEY= (gitignored)
├── gelbooru-api-credentials.txt # Gelbooru: USER_ID= / API_KEY= / USERNAME= (gitignored)
├── tags.txt                # Tag queries (gitignored)
├── blacklist.txt           # Blacklist rules (gitignored)
└── test/                   # Minitest suite
```

## API Reference: e621

### Base URL & Auth
- `https://e621.net` — all endpoints use `/posts.json`, `/uploads.json`, etc.
- Auth: Basic auth via `Authorization` header, or `login`+`api_key` query params
- API key generated at Account > My profile
- **User-Agent required** — custom descriptive string, never impersonate a browser
- **Rate limit:** 2 req/s hard cap, best effort ≤1 req/s sustained
- **CORS:** GET + POST simple requests allowed cross-origin; PATCH/PUT/DELETE not

### Source Code
- e621: `https://github.com/e621ng/e621ng` (Rails, MIT, 544★, 12,469 commits)
- Danbooru (upstream): `https://github.com/danbooru/danbooru` (Rails, 2.8k★, 14,571 commits)

### v1/v2 Response Format Migration
- **Phase 1 (Now — Dec 2026):** Legacy (v1) default, `v2=true` opts in
- **Phase 2 (Dec 2026 — May 2027):** New (v2) default, `v1=true` keeps legacy
- **Phase 3 (May 2027+):** Legacy format removed entirely
- Affects all post endpoints: `/posts.json`, show, random, md5 lookups

### v2 Format Details
- No more `{ "posts": [...] }` wrapper — raw array/object directly
- `mode` parameter controls tag detail:
  - `mode=basic` — tags as flat array (default, faster)
  - `mode=extended` — tags grouped by category (legacy-compatible)
  - `mode=thumbnails` — lightweight for grid views
- Fields grouped into `files`, `stats`, `flags`, `has`, `relationships` objects
- Legacy `only` parameter removed

### v2 Post Response Structure
```json
{
  "id": 4149486,
  "created_at": "2023-07-04T01:21:33.766-07:00",
  "updated_at": "2026-05-06T07:49:00.191-07:00",
  "change_seq": 70845555,
  "files": {
    "meta": { "md5": "...", "ext": "png", "size": 6749159, "duration": null, "has_sample": true },
    "original": { "width": 1874, "height": 1970, "url": "https://static1.e621.net/data/..." },
    "preview": { "width": 256, "height": 269, "jpg": "...", "webp": "..." },
    "sample": { "width": 850, "height": 894, "jpg": "...", "webp": "..." }
  },
  "uploader_id": 509791,
  "uploader_name": "gattonero2001",
  "approver_id": 12286,
  "stats": { "score": { "up": 3992, "down": -29, "total": 3963 }, "fav_count": 6125, "is_favorited": false, "comment_count": 81 },
  "flags": { "pending": false, "flagged": false, "note_locked": false, "status_locked": false, "rating_locked": false, "deleted": false },
  "has": { "parent": false, "children": false, "active_children": false, "notes": false, "sample": true },
  "relationships": { "parent_id": null, "children": [] },
  "pools": [],
  "rating": "s",
  "locked_tags": [],
  "sources": ["https://..."],
  "description": "",
  "tags": []
}
```

### e621 Endpoints
| Function | Endpoint | Method |
|----------|----------|--------|
| Search posts | `/posts.json` | GET |
| Upload | `/uploads.json` | POST |
| Update post | `/posts/<id>.json` | PATCH |
| Search flags | `/post_flags.json` | GET |
| Create flag | `/post_flags.json` | POST |
| Vote | `/posts/<id>/votes.json` | POST |
| Favorite | `/favorites.json` | POST |
| Delete favorite | `/favorites/<id>.json` | DELETE |
| Search notes | `/notes.json` | GET |
| Create note | `/notes.json` | POST |
| Update note | `/notes/<id>.json` | PUT |
| Delete note | `/notes/<id>.json` | DELETE |
| Revert note | `/notes/<id>/revert.json` | PUT |
| Search pools | `/pools.json` | GET |
| Create pool | `/pools.json` | POST |
| Update pool | `/pools/<id>.json` | PUT |
| Revert pool | `/pools/<id>/revert.json` | PUT |

### e621 Tag Categories
- `0` general, `1` artist, `2` contributor, `3` copyright, `4` character, `5` species, `6` invalid, `7` meta, `8` lore

### e621 Tag Search Parameters
- `search[name_matches]` — wildcard with `*`
- `search[category]` — numeric category filter
- `search[order]` — `date`, `count`, `name`
- `search[hide_empty]` — `true`/`false`
- `search[has_wiki]` — `true`/`false`/blank
- `search[has_artist]` — `true`/`false`/blank
- `limit` — max 320
- `page` — `a<id>` (after), `b<id>` (before), or numeric

### e621 HTTP Status Codes
- `200` OK, `204` No Content (delete), `400` unavailable feature, `401` bad auth, `403` forbidden (missing UA), `404` not found, `405` wrong method, `406` format not allowed, `410` gone (invalid pagination), `412` precondition failed (upload invalid/duplicate), `422` invalid param, `429` rate limited, `500` server error, `502` bad gateway, `503` unavailable/rate limit, `520` unknown, `522` CF timeout, `524` CF timeout, `525` SSL failure

### OpenAPI Spec
- Community maintained at `https://e621.wiki/openapi.yaml`

## API Reference: Gelbooru

### Base URL & Auth
- `https://gelbooru.com/index.php?page=dapi&s=post&q=index`
- Auth via query params: `api_key=...&user_id=...`
- Rate throttling enforced for non-Patreon supporters

### Gelbooru Endpoints
| Function | Endpoint |
|----------|----------|
| Search posts | `?page=dapi&s=post&q=index` with `tags`, `pid`, `limit`, `json=1` |
| Search tags | `?page=dapi&s=tag&q=index` with `name`, `name_pattern`, `order`, `orderby` |
| Search users | `?page=dapi&s=user&q=index` with `name`, `name_pattern` |
| Get comments | `?page=dapi&s=comment&q=index` with `post_id` |
| Deleted images | `?page=dapi&s=post&q=index&deleted=show` with `last_id` |

### Gelbooru Post Parameters
- `limit` — default 100
- `pid` — page number (0-indexed)
- `tags` — tag search (same as web)
- `cid` — change ID (Unix time)
- `id` — specific post ID
- `json=1` — JSON response

### Gelbooru Tag Parameters
- `id` — specific tag
- `limit` — default 100
- `after_id` — tags with ID > this value
- `name` — exact name search
- `names` — space-separated multi-tag lookup
- `name_pattern` — LIKE wildcard (`_` single, `%` multi)
- `order` / `orderby` — `date`, `count`, `name`; `ASC`/`DESC`

## How to Run
```bash
ruby rubichiver.rb --site e621 [OPTIONS]
ruby rubichiver.rb --site gelbooru [OPTIONS]

# Common options
  -o, --output DIR          Output directory
  -t, --tags FILE           Tags file (default: ./tags.txt)
  -c, --credentials FILE    API credentials file
  --dry-run                 Show what would be done
  -v, --verbose             Verbose output
  --json                    JSON log output
  -j, --threads N           Worker threads (default: 2)
  --rate-limit N            API requests per second (default: 1)
  -b, --blacklist FILE      Blacklist file (e621 syntax)

# e621-specific
  --notify URL              POST JSON run report on completion
  --recheck-sidecars        Recheck/regen missing/invalid sidecars
  -C, --cache-dir DIR       API response cache directory
```

## Key Conventions
- **Unified runner** — `--site e621|gelbooru` dispatches to the correct archiver subclass
- **ArchiverBase** — shared run loop: load credentials → build post list → enqueue → process → report
- **Post discovery** — per-line tag queries from `tags.txt`, paginated via `fetch_all_posts_for_query`
- **Deduplication** — `$existing_posts` hash map (post_id → file_path) scanned at startup; per-run `Set` of seen IDs
- **Existing file handling** — sidecar missing → regenerate; sidecar valid → skip
- **Parallelism** — `PostProcessor` worker pool, configurable thread count
- **Interrupt handling** — first Ctrl+C graceful shutdown, second force exit
- **Rate limiting** — `RateLimiter` class with configurable requests/sec
- **No transcoding** — media kept in original format; only XMP sidecars written
- **XMP sidecars** — `XMP:Rating` (1-3) + categorized keywords (`category:tag`) via ExifTool
- **Blacklist** — e621 syntax: `~OR` groups, `-negation`, `rating:`, `id:`; applied per-post before enqueue
- **Unsupported formats** — SWF files skipped
- **Error handling** — retries with exponential backoff (3 attempts) on network errors
- **Notification** — `--notify URL` POSTs JSON report; failures logged never abort
- **Exit codes** — `0` success, `1` interrupted or any failure

## Testing
- Framework: Minitest (stdlib)
- Run: `ruby -Itest test/all.rb`
- Tests: blacklist parser, rate limiter, post/sidecar processing, API pagination, HTTP redirects, integration stubs
