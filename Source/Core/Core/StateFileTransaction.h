// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <string>

namespace State::detail
{
enum class CommitStateFileResult
{
  Failed,
  Saved,
  SavedWithoutUndo,
};

// FileOps provides Close, Exists, SameFile, StagePrevious, Replace and Remove. The current file is never
// moved aside: a failed write, close or atomic replacement leaves it and the old undo untouched.
// Undo housekeeping happens after the primary commit and cannot turn a successful save into failure.
template <typename FileOps>
CommitStateFileResult CommitStateFile(FileOps& files, const std::string& temporary,
                                     const std::string& destination, const std::string& undo,
                                     bool write_succeeded)
{
  const bool closed = files.Close();
  if (!write_succeeded || !closed)
  {
    files.Remove(temporary);
    return CommitStateFileResult::Failed;
  }

  // SaveAs accepts arbitrary paths, including the reserved undo path itself.
  const bool had_previous = destination != undo && !files.SameFile(destination, undo) &&
                            files.Exists(destination);
  const std::string previous = temporary + ".previous";
  if (had_previous && !files.StagePrevious(destination, previous))
  {
    files.Remove(previous);
    files.Remove(temporary);
    return CommitStateFileResult::Failed;
  }
  if (!files.Replace(temporary, destination))
  {
    files.Remove(previous);
    files.Remove(temporary);
    return CommitStateFileResult::Failed;
  }
  if (had_previous && !files.Replace(previous, undo))
  {
    files.Remove(previous);
    return CommitStateFileResult::SavedWithoutUndo;
  }
  return CommitStateFileResult::Saved;
}
}  // namespace State::detail
