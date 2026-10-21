// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_set>
namespace ciface::iOS
{
class ControllerInputGate final
{
public:
  using Token = std::uint64_t;
  Token Acquire()
  {
    std::lock_guard lock(m_mutex);
    if (m_disconnected)
      return 0;
    const Token token = ++m_next_token;
    m_tokens.insert(token);
    m_suppressed.store(true, std::memory_order_release);
    return token;
  }
  // A release never exposes the closing press. Only a subsequent physical snapshot may do so.
  void RequestRelease(Token token)
  {
    std::lock_guard lock(m_mutex);
    if (m_tokens.erase(token))
      m_pending_neutral = true;
  }
  // Run the physical snapshot under the same lock as release admission, so a snapshot taken
  // before RequestRelease cannot accidentally acknowledge a later closing input.
  template <typename Snapshot> void PollNeutral(Snapshot&& snapshot)
  {
    std::lock_guard lock(m_mutex);
    if (!m_disconnected && m_pending_neutral && m_tokens.empty() && snapshot())
    {
      m_pending_neutral = false;
      m_suppressed.store(false, std::memory_order_release);
    }
  }
  // Old wrappers may outlive removal on another polling thread. Keep them permanently neutral.
  void Disconnect()
  {
    std::lock_guard lock(m_mutex);
    m_disconnected = true;
    m_tokens.clear();
    m_pending_neutral = false;
    m_suppressed.store(true, std::memory_order_release);
  }
  bool IsDisconnected() const
  {
    std::lock_guard lock(m_mutex);
    return m_disconnected;
  }
  bool IsSuppressed() const { return m_suppressed.load(std::memory_order_acquire); }

private:
  mutable std::mutex m_mutex;
  std::unordered_set<Token> m_tokens;
  Token m_next_token = 0;
  bool m_pending_neutral = false;
  bool m_disconnected = false;
  std::atomic<bool> m_suppressed{false};
};
}
