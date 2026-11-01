module dwk

// Minimum language version only (no patch level), so any 1.27+ toolchain builds it. The exact toolchain is pinned
// once, by the digest-pinned golang image in the Dockerfile, which Dependabot keeps current.
go 1.27
