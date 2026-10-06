// TempBlobStore.swift
//
// `BlobStore`'s base directory is always injected (see its own doc comment)
// specifically so tests never touch the real `~/Library/Application
// Support` path — this is the one place `PickerViewModelTests` creates that
// throwaway directory, per coding-standards.md ("NO real disk in the app-
// support path... from a test").

import ClipnestCore
import Foundation

/// Creates a fresh temp directory and a `BlobStore` rooted there. Callers
/// that don't need the directory back can ignore the first tuple element;
/// `PickerViewModelTests` uses it to remove the directory again in a
/// `defer` so repeated test runs don't accumulate throwaway blob
/// directories under `/tmp`.
func makeTempBlobStore() -> (directory: URL, blobStore: BlobStore) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("ClipnestAppTests-\(UUID().uuidString)", isDirectory: true)
  return (directory, BlobStore(baseDirectory: directory))
}
