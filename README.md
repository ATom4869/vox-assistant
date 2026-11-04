# VOX Assistant — Release artefacts

Repo publik untuk artefak rilis VOX Assistant (headless agent `voxy`).
File-file di sini **bukan source code** — hanya manifest dan biner hasil build.

## Isi

- `latest.json` — manifest rilis terbaru (dibaca `install.sh` saat instalasi one-liner)
- **GitHub Release** (`v<version>`) — biner + installer desktop:
  - `voxy-linux-x86_64-<version>` — headless binary Linux x86_64
  - `voxy-linux-aarch64-<version>` — headless binary Linux aarch64
  - `voxy-setup-<version>-x64.exe` — installer Windows (NSIS)
  - `voxy-linux-<arch>-<version>.deb` — paket Debian/Ubuntu
  - `voxy-linux-<arch>-<version>.AppImage` — AppImage Linux
  - `.sha256` + `.minisig` untuk setiap artefak

## Install (VPS)

```sh
curl -fsSL https://votrexian.ai.id/vox/install.sh | sh
```

## Instalasi desktop

Lihat halaman `https://votrexian.ai.id/install` di situs, tab **Desktop**.

## Catatan

Repo development (source code) bersifat private dan terpisah. Repo ini hanya
untuk distribusi artefak publik tanpa perlu token.
