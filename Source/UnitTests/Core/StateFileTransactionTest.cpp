// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <map>
#include <filesystem>
#include <string>

#include <gtest/gtest.h>

#include "Core/StateFileTransaction.h"

namespace
{
struct Files
{
  std::map<std::string, std::string> contents{{"slot", "old"}, {"undo", "undo"}, {"temp", "new"}};
  bool close_ok = true;
  bool stage_ok = true;
  bool replace_ok = true;
  bool undo_ok = true;
  int closes = 0;
  static std::string Key(const std::string& path) { return std::filesystem::path(path).lexically_normal().string(); }

  bool Close() { ++closes; return close_ok; }
  bool Exists(const std::string& path) { return contents.contains(Key(path)); }
  bool SameFile(const std::string& a, const std::string& b) { return Key(a) == Key(b); }
  bool StagePrevious(const std::string& source, const std::string& destination)
  {
    if (!stage_ok)
      return false;
    contents[Key(destination)] = contents.at(Key(source));
    return true;
  }
  bool Replace(const std::string& source, const std::string& destination)
  {
    if ((destination == "slot" && !replace_ok) || (destination == "undo" && !undo_ok))
      return false;
    contents[Key(destination)] = contents.at(Key(source));
    contents.erase(Key(source));
    return true;
  }
  void Remove(const std::string& path) { contents.erase(Key(path)); }
};
using State::detail::CommitStateFile;
using State::detail::CommitStateFileResult;
}  // namespace

TEST(StateFileTransaction, WriteFailurePreservesCurrentAndUndo)
{
  Files files;
  EXPECT_EQ(CommitStateFile(files, "temp", "slot", "undo", false), CommitStateFileResult::Failed);
  EXPECT_EQ(files.contents.at("slot"), "old");
  EXPECT_EQ(files.contents.at("undo"), "undo");
  EXPECT_EQ(files.closes, 1);
  EXPECT_FALSE(files.Exists("temp"));
}

TEST(StateFileTransaction, CloseFailurePreservesCurrentAndUndo)
{
  Files files;
  files.close_ok = false;
  EXPECT_EQ(CommitStateFile(files, "temp", "slot", "undo", true), CommitStateFileResult::Failed);
  EXPECT_EQ(files.contents.at("slot"), "old");
  EXPECT_EQ(files.contents.at("undo"), "undo");
}

TEST(StateFileTransaction, UndoStagingFailurePreservesCurrentAndUndo)
{
  Files files;
  files.stage_ok = false;
  EXPECT_EQ(CommitStateFile(files, "temp", "slot", "undo", true), CommitStateFileResult::Failed);
  EXPECT_EQ(files.contents.at("slot"), "old");
  EXPECT_EQ(files.contents.at("undo"), "undo");
}

TEST(StateFileTransaction, PromotionFailurePreservesCurrentAndUndo)
{
  Files files;
  files.replace_ok = false;
  EXPECT_EQ(CommitStateFile(files, "temp", "slot", "undo", true), CommitStateFileResult::Failed);
  EXPECT_EQ(files.contents.at("slot"), "old");
  EXPECT_EQ(files.contents.at("undo"), "undo");
  EXPECT_FALSE(files.Exists("temp.previous"));
}

TEST(StateFileTransaction, SuccessfulCommitKeepsPreviousInUndo)
{
  Files files;
  EXPECT_EQ(CommitStateFile(files, "temp", "slot", "undo", true), CommitStateFileResult::Saved);
  EXPECT_EQ(files.contents.at("slot"), "new");
  EXPECT_EQ(files.contents.at("undo"), "old");
}

TEST(StateFileTransaction, UndoHousekeepingFailureStillReportsCommittedPrimary)
{
  Files files;
  files.undo_ok = false;
  EXPECT_EQ(CommitStateFile(files, "temp", "slot", "undo", true), CommitStateFileResult::SavedWithoutUndo);
  EXPECT_EQ(files.contents.at("slot"), "new");
  EXPECT_EQ(files.contents.at("undo"), "undo");
}

TEST(StateFileTransaction, FirstSaveDoesNotReplaceUnrelatedUndo)
{
  Files files;
  files.contents.erase("slot");
  EXPECT_EQ(CommitStateFile(files, "temp", "slot", "undo", true), CommitStateFileResult::Saved);
  EXPECT_EQ(files.contents.at("slot"), "new");
  EXPECT_EQ(files.contents.at("undo"), "undo");
}

TEST(StateFileTransaction, SavingDirectlyToUndoPathDoesNotRestoreOldBytes)
{
  Files files;
  EXPECT_EQ(CommitStateFile(files, "temp", "undo", "undo", true), CommitStateFileResult::Saved);
  EXPECT_EQ(files.contents.at("undo"), "new");
  EXPECT_EQ(files.contents.at("slot"), "old");
}

TEST(StateFileTransaction, AliasedUndoPathDoesNotRestoreOldBytes)
{
  Files files;
  EXPECT_EQ(CommitStateFile(files, "temp", "./undo", "undo", true), CommitStateFileResult::Saved);
  EXPECT_EQ(files.contents.at("undo"), "new");
}
