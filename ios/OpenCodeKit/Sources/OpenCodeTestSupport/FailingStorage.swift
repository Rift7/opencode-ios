import Foundation
import OpenCodeCore

/// A storage double that always fails with the given reason, for exercising failure paths
/// deterministically.
public struct FailingStorage: KeyValueStorage {
  public let failure: StorageFailure

  public init(failure: StorageFailure) {
    self.failure = failure
  }

  public func read(_ key: String) -> StorageRead { .failure(failure) }
  public func write(_ data: Data, for key: String) -> StorageWrite { .failure(failure) }
  public func delete(_ key: String) -> StorageWrite { .failure(failure) }
}

/// A keychain-operations double that returns scripted outcomes, so a keychain store can be tested
/// without the Security framework.
public final class ScriptedKeychainOperations: KeychainOperations, Sendable {
  private let readResult: StorageRead
  private let writeResult: StorageWrite
  private let deleteResult: StorageWrite

  public init(
    read: StorageRead = .missing,
    write: StorageWrite = .success,
    delete: StorageWrite = .success
  ) {
    readResult = read
    writeResult = write
    deleteResult = delete
  }

  public func read(service: String, account: String) -> StorageRead { readResult }
  public func write(_ data: Data, service: String, account: String) -> StorageWrite { writeResult }
  public func delete(service: String, account: String) -> StorageWrite { deleteResult }
}
