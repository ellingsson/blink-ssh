SwiftTerm source pin

Upstream: https://github.com/migueldeicaza/SwiftTerm
Version: v1.11.2
Commit: b1262db5b6bea699a8260a8c66999436c508ca56

Package.swift is intentionally reduced to the source-only SwiftTerm library target. Benchmarking, documentation, command-line tools, and their mutable package dependencies are excluded from the SSH-only application build.
