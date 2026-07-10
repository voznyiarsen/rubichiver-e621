# rubichiver — Unified Booru Media Archiver

Downloads media from e621.net and Gelbooru with XMP sidecar metadata (rating + categorized keywords).

## Requirements

- Ruby 3.x (stdlib)
- [ExifTool](https://exiftool.org/)

Create credentials files (gitignored):

```
# e621-api-credentials.txt
USERNAME=your_username
API_KEY=your_api_key

# gelbooru-api-credentials.txt
USER_ID=your_user_id
API_KEY=your_api_key
USERNAME=your_username
```

## Usage

```bash
ruby rubichiver.rb --site e621 [OPTIONS]
ruby rubichiver.rb --site gelbooru [OPTIONS]
```

### Common options

| Flag | Description |
|------|-------------|
| `-o DIR` | Output directory |
| `-t FILE` | Tags file (default: `./tags.txt`) |
| `-c FILE` | API credentials file |
| `-b FILE` | Blacklist file (default: `./blacklist.txt`) |
| `--dry-run` | Preview posts that would be archived |
| `-v` | Verbose output |
| `--json` | JSON log output |
| `-j N` | Worker threads (default: 2) |
| `--rate-limit N` | API requests/second (default: 1) |
| `--notify URL` | POST JSON report to webhook on completion |

### e621-specific

| Flag | Description |
|------|-------------|
| `-C DIR` | API response cache directory |
| `--recache-post-tags` | Refresh tag cache for all existing posts from API |

### Tags file

One query per line, space-separated tags:

```
furry -rating:s
species:canine
character:fido
```

### Blacklist file

e621 syntax: `~OR` groups, `-negation`, `rating:`, `id:`:

```
gore -rating:e
~fox wolf
rating:explicit
id:12345
```

## License

ISC
