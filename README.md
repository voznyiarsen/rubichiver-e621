# rubichiver-e621

A Ruby CLI tool that downloads media from e621.net and writes XMP sidecar metadata files. Keeps files in their original format — no transcoding.

## Features

- Fetches post metadata from the e621 v2 JSON API (paginated, 320 per page)
- Downloads media in original format (webm, avi, mov, png, jpg, etc.)
- Writes `.xmp` sidecar files with `XMP:Rating` and `IPTC:Keywords` (categorized tags)
- File-based API response caching (persistent across runs)
- Threaded worker pool for concurrent downloads
- e621 blacklist syntax support (`~OR`, `-negation`, `rating:`, `id:`)
- Exponential backoff retry on failed downloads

## Requirements

- Ruby 3.x (stdlib only, no gems required)
- [ExifTool](https://exiftool.org/) — for XMP sidecar writing

## Installation

```
git clone https://github.com/your-username/rubichiver-e621.git
cd rubichiver-e621
```

## Usage

```
ruby rubichiver-e621.rb [OPTIONS]

Options:
  -o, --output DIR        Output directory (default: ./e6archive)
  -t, --tags FILE         Tags file (default: ./tags.txt)
  -c, --credentials FILE  API credentials file (default: ./api_credentials.txt)
  --dry-run               Show what would be done without downloading
  -v, --verbose           Verbose output
  --json                  JSON log output (machine-parseable)
  -j, --threads N         Worker threads (default: 2)
  --rate-limit N          API requests per second (default: 1)
  -h, --help              Show this help message
```

### Tags file format

One query per line. Tags within a line are space-separated:

```
furry -rating:s
species:canine
character:fido
```

### Credentials file format

```
USERNAME=your_e621_username
API_KEY=your_e621_api_key
```

### Blacklist file format

Standard e621 blacklist syntax:

```
gore -rating:s
~comic porn
rating:explicit
```

## License

ISC
