#include "InputCommon/ControllerInterface/iOS/ControllerInputGate.h"
#include <cassert>
#include <thread>
#include <iostream>
using ciface::iOS::ControllerInputGate;
int main()
{
  auto remote = std::make_shared<ControllerInputGate>();
  auto pad = std::make_shared<ControllerInputGate>();
  assert(!remote->IsSuppressed());
  bool sampled_without_pending_release = false;
  remote->PollNeutral([&] { sampled_without_pending_release = true; return true; });
  assert(!sampled_without_pending_release);
  auto first = remote->Acquire();
  assert(remote->IsSuppressed() && !pad->IsSuppressed());
  auto refreshed_wrapper = remote;
  assert(refreshed_wrapper->IsSuppressed());
  auto second = remote->Acquire();
  remote->RequestRelease(first);
  remote->PollNeutral([] { return true; });
  assert(remote->IsSuppressed());
  remote->RequestRelease(second);
  remote->PollNeutral([] { return false; });
  assert(remote->IsSuppressed());
  remote->PollNeutral([] { return true; });
  assert(!remote->IsSuppressed());
  remote->RequestRelease(first); // duplicate/stale release cannot release a new owner
  auto third = remote->Acquire();
  remote->PollNeutral([] { return true; });
  assert(remote->IsSuppressed());
  std::thread poll([&] { for (int i = 0; i < 100000; ++i) assert(remote->IsSuppressed()); });
  for (int i = 0; i < 1000; ++i) { auto token = remote->Acquire(); remote->RequestRelease(token); }
  poll.join();
  remote->RequestRelease(third);
  remote->PollNeutral([] { return true; });
  assert(!remote->IsSuppressed());
  remote->Acquire();
  remote->Disconnect();
  assert(remote->IsSuppressed()); // detached old wrappers are permanently neutral
  remote->PollNeutral([] { return true; });
  assert(remote->IsSuppressed());
  assert(remote->Acquire() == 0);
  assert(remote->IsDisconnected());
  std::cout << "controller input gate: all assertions passed\n";
}
