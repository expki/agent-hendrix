# webgpu-lsp

A Claude Code plugin that gives Claude a **WGSL / WESL language server** for WebGPU
shader development. It wires [`wgsl-analyzer`](https://github.com/wgsl-analyzer/wgsl-analyzer)
into Claude Code's `lspServers`, so Claude gets real code intelligence on shader files
instead of guessing.

It activates on `.wgsl` and `.wesl` files. Claude reaches the server two ways — Claude
Code's `LSP` tool (its nine operations) and diagnostics surfaced automatically on
edits. What's actually useful is the intersection of those with what upstream
`wgsl-analyzer` nightly implements:

## Features

Verified end-to-end against nightly `0.12.395`:

| # | `LSP` operation | Advertised | Result |
| --- | --- | --- | --- |
| - | `edit-feedback` | ✅ | ✅ Works — identifies issues when editing |
| 1 | `goToDefinition` | ✅ | ✅ Works — resolves functions and types |
| 2 | `findReferences` | — | ❌ `unknown request` (-32601) ([wa#347]) |
| 3 | `hover` | ✅ | ⚠️ Returns null ([wa#362]) |
| 4 | `documentSymbol` | — | ❌ `unknown request` (-32601) ([wa#349]) |
| 5 | `workspaceSymbol` | — | ❌ `unknown request` (-32601) ([wa#350]) |
| 6 | `goToImplementation` | — | ❌ `unknown request` (-32601) — N/A to WGSL |
| 7 | `prepareCallHierarchy` | — | ❌ `unknown request` (-32601) ([wa#343]) |
| 8 | `incomingCalls` | — | ❌ `unknown request` (-32601) ([wa#343]) |
| 9 | `outgoingCalls` | — | ❌ `unknown request` (-32601) ([wa#343]) |

[wa#362]: https://github.com/wgsl-analyzer/wgsl-analyzer/issues/362
[wa#347]: https://github.com/wgsl-analyzer/wgsl-analyzer/issues/347
[wa#349]: https://github.com/wgsl-analyzer/wgsl-analyzer/issues/349
[wa#350]: https://github.com/wgsl-analyzer/wgsl-analyzer/issues/350
[wa#343]: https://github.com/wgsl-analyzer/wgsl-analyzer/issues/343

## Install

```bash
claude plugin marketplace add expki/agent-hendrix
claude plugin install webgpu-lsp@agent-hendrix
```

Restart Claude Code, then open a `.wgsl` or `.wesl` file. On first use the plugin
downloads the prebuilt `wgsl-analyzer` binary from upstream's rolling `nightly`
release and caches it.

## Notes

- **Supported platforms** — prebuilt binaries cover Linux (x86_64 gnu/musl, aarch64,
  armv7), macOS (Apple Silicon), and Windows (x86_64, aarch64). On Intel macOS or an
  offline machine, build from source instead (needs Rust ≥ 1.96):
  ```bash
  git clone --recursive https://github.com/expki/agent-hendrix.git
  ./agent-hendrix/webgpu-lsp/scripts/build-server.sh
  ```
