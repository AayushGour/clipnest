// main.swift — Clipnest's Linux executable entry point.
//
// Deliberately the thinnest possible shim: all real orchestration lives in
// `LinuxAppLifecycle.run(arguments:)` so it stays unit-testable/readable
// as ordinary code rather than top-level script statements. See that
// type's doc comment for the full startup sequence.

import ClipnestLinuxAppKit

LinuxAppLifecycle.run(arguments: CommandLine.arguments)
