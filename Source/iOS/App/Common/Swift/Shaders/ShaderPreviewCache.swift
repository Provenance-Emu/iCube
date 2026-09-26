// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

// D16 follow-up: bounded, cancellable cache/scheduler in front of
// `ShaderPreviewRenderer`. See that file's header for why this exists instead
// of reusing iFly's `ShaderPreviewGenerator` (that type drives the shared
// `DOLShaderPostProcessor` singleton; this one never touches it).
import CoreGraphics
import Foundation

/// Identifies one rendered preview: which preset, against which source frame,
/// at what size. `sourceMTime` (rather than a hash of the frame's bytes) is
/// enough to invalidate stale entries cheaply — a new pause always writes a
/// fresh `SaveStateService.pausePreviewURL` with a new modification date, and
/// `ShaderQuickPickerView` already treats that file as scoped to "the current
/// pause" via the same freshness window it uses for the hero backdrop.
struct ShaderPreviewCacheKey: Hashable {
  let presetPath: String
  let sourceMTime: TimeInterval
  let thumbnailWidth: Int

  init(presetPath: String, sourceMTime: TimeInterval, thumbnailWidth: Int = Int(ShaderPreviewRenderer.thumbnailSize.width)) {
    self.presetPath = presetPath
    self.sourceMTime = sourceMTime
    self.thumbnailWidth = thumbnailWidth
  }
}

/// Plain, synchronous least-recently-used cache. Deliberately has no async/Metal
/// dependency of its own so its eviction/keying behavior is unit-testable
/// without a device — see `ShaderPreviewCacheTests`.
struct LRUCache<Key: Hashable, Value> {
  private(set) var capacity: Int
  private var storage: [Key: Value] = [:]
  /// Least-recently-used first, most-recently-used last.
  private var order: [Key] = []

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  var count: Int { storage.count }

  func value(forKey key: Key) -> Value? {
    storage[key]
  }

  mutating func setValue(_ value: Value, forKey key: Key) {
    storage[key] = value
    touch(key)
    evictIfNeeded()
  }

  /// Marks `key` as most-recently-used without changing its value. Callers
  /// should do this on every read hit so eviction order reflects actual usage.
  mutating func markUsed(_ key: Key) {
    guard storage[key] != nil else { return }
    touch(key)
  }

  mutating func removeValue(forKey key: Key) {
    storage.removeValue(forKey: key)
    order.removeAll { $0 == key }
  }

  mutating func removeAll() {
    storage.removeAll()
    order.removeAll()
  }

  private mutating func touch(_ key: Key) {
    if let idx = order.firstIndex(of: key) {
      order.remove(at: idx)
    }
    order.append(key)
  }

  private mutating func evictIfNeeded() {
    while storage.count > capacity, !order.isEmpty {
      let oldest = order.removeFirst()
      storage.removeValue(forKey: oldest)
    }
  }
}

/// Serializes access to the LRU cache, de-duplicates concurrent requests for the
/// same key, and caps how many `ShaderPreviewRenderer` compiles/renders can run
/// at once — bundled shader compiles are CPU/GPU-heavy enough that letting an
/// entire grid of ~20+ cards render simultaneously would contend badly with
/// whatever else is on screen.
actor ShaderPreviewCache {
  static let shared = ShaderPreviewCache()

  /// A few at a time, per the task spec — not so many that scrolling a full
  /// grid saturates the GPU, not so few that the grid fills in visibly slowly.
  private static let maxConcurrentRenders = 2

  private var cache = LRUCache<ShaderPreviewCacheKey, CGImage>(capacity: 32)
  private var inFlight: [ShaderPreviewCacheKey: Task<CGImage?, Never>] = [:]

  // MARK: - Concurrency-limiting "slot" (async semaphore)

  private var activeRenders = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  private func acquireSlot() async {
    if activeRenders < Self.maxConcurrentRenders {
      activeRenders += 1
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(continuation)
    }
    // A waiting caller is handed an already-reserved slot by `releaseSlot()`
    // below (a direct hand-off, not "free one then race to grab it") — do NOT
    // increment `activeRenders` again here, or a hand-off would double-count.
  }

  private func releaseSlot() {
    if !waiters.isEmpty {
      let next = waiters.removeFirst()
      next.resume() // transfers the slot directly; activeRenders is unchanged.
    } else {
      activeRenders = max(0, activeRenders - 1)
    }
  }

  // MARK: - Public API

  private init() {}

  /// Synchronous-ish cache probe: returns an already-rendered thumbnail without
  /// starting new work. Callers use this to paint instantly on reappearance
  /// (e.g. reopening the sheet) before falling back to `preview(...)`.
  func cachedImage(forKey key: ShaderPreviewCacheKey) -> CGImage? {
    if let hit = cache.value(forKey: key) {
      cache.markUsed(key)
      return hit
    }
    return nil
  }

  /// Returns a cached thumbnail for `presetPath` immediately if one exists, else
  /// renders (or joins an in-flight render for the same key), respecting the
  /// caller's own `Task` cancellation. `sourceImage` is only evaluated if a
  /// fresh render is actually needed.
  func preview(
    presetPath: String,
    presetURL: URL,
    sourceImage: @autoclosure () -> CGImage?,
    sourceMTime: TimeInterval,
    thumbnailWidth: Int = Int(ShaderPreviewRenderer.thumbnailSize.width),
    timeout: TimeInterval = ShaderPreviewRenderer.defaultTimeout
  ) async -> CGImage? {
    let key = ShaderPreviewCacheKey(presetPath: presetPath, sourceMTime: sourceMTime, thumbnailWidth: thumbnailWidth)

    if let hit = cachedImage(forKey: key) { return hit }
    guard !Task.isCancelled else { return nil }

    if let joined = inFlight[key] {
      let result = await joined.value
      return Task.isCancelled ? nil : result
    }

    guard let image = sourceImage() else { return nil }

    let renderTask = Task<CGImage?, Never> { [weak self] in
      await self?.acquireSlot()
      return await ShaderPreviewRenderer.renderPreview(
        presetURL: presetURL,
        sourceImage: image,
        timeout: timeout,
        onRealWorkCompleted: { [weak self] in
          // Fires when the background render ACTUALLY finishes, which may be
          // well after this Task's `await` above already returned (the render
          // outlives a timed-out caller) — see `ShaderPreviewRenderer`'s header.
          Task { await self?.releaseSlot() }
        }
      )
    }
    inFlight[key] = renderTask

    let result = await renderTask.value
    inFlight[key] = nil

    guard let result else { return nil }
    cache.setValue(result, forKey: key)
    return Task.isCancelled ? nil : result
  }

  /// Test/debug hook — not called from production UI code.
  func removeAll() {
    cache.removeAll()
  }
}
