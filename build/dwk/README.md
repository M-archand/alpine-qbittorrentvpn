# DWK (Derive WebUI Key)

Small helper that derives the `WebUI\Password_PBKDF2` value qBittorrent expects
(PBKDF2-HMAC-SHA512, 100000 iterations, 64 byte key) using only the Go standard library.

Usage:

```sh
printf '%s' "$password" | dwk [<salt (base64)>] [<iterations>]
```

The password is read from stdin so it never shows up in `/proc/<pid>/cmdline`.
Output is two lines: the base64 salt (random 16 bytes when not given) and the base64 key.
qBittorrent stores them as `@ByteArray(<salt>:<key>)`.
