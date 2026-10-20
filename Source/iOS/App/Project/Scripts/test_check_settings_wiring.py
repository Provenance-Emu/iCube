#!/usr/bin/env python3
"""Regression coverage for reset helpers that operate on Config locations."""
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import check_settings_wiring as lint


HELPER = '''
static bool IsCirKey(const Config::Location& location) {
  return location.system == Config::System::Main &&
    Common::CaseInsensitiveEquals(location.section, "Core") && location.key.size() > 3 &&
    Common::CaseInsensitiveEquals(std::string_view(location.key).substr(0, 3), "CIR");
}
static void DeleteCirKeys(Config::LayerType layer_type) {
  const auto layer = Config::GetLayer(layer_type);
  if (!layer) return;
  for (const auto& [location, value] : layer->GetLayerMap()) {
    if (value && IsCirKey(location)) layer->DeleteKey(location);
  }
}
+ (void)resetGameplayConfigKeys {
  for (auto lt : kLayers) DeleteCirKeys(lt);
}
'''
DEFINITIONS = '''
const Info<bool> ALIAS_WITHOUT_CIR_NAME{{System::Main, "cOrE", "cirRealKnob"}, false};
const Info<bool> MAIN_CIR_MISLEADING{{System::Main, "Core", "Unrelated"}, false};
const Info<bool> WRONG_SYSTEM{{System::GFX, "Core", "CIRKnob"}, false};
const Info<bool> WRONG_SECTION{{System::Main, "Other", "CIRKnob"}, false};
const Info<bool> PREFIX_ONLY{{System::Main, "Core", "CIR"}, false};
'''


class CirResetCoverageTests(unittest.TestCase):
    def test_coverage_follows_real_locations_not_symbol_prefixes(self):
        self.assertEqual(lint.cir_reset_keys(HELPER, DEFINITIONS), {"ALIAS_WITHOUT_CIR_NAME"})

    def test_no_coverage_when_global_reset_does_not_invoke_helper(self):
        self.assertEqual(lint.cir_reset_keys(HELPER.replace("DeleteCirKeys(lt);", "OtherReset(lt);"), DEFINITIONS), set())

    def test_no_coverage_without_actual_location_deletion(self):
        self.assertEqual(lint.cir_reset_keys(HELPER.replace("layer->DeleteKey(location);", "Inspect(location);"), DEFINITIONS), set())

    def test_commented_out_helper_call_does_not_cover_keys(self):
        self.assertEqual(lint.cir_reset_keys(HELPER.replace("DeleteCirKeys(lt);", "/* DeleteCirKeys(lt); */"), DEFINITIONS), set())

    def test_unrecognized_predicate_requires_review(self):
        self.assertEqual(lint.cir_reset_keys(HELPER.replace('"CIR"', '"OTHER"'), DEFINITIONS), set())

    def test_current_bridge_and_real_config_definitions_resolve_cir_keys(self):
        sources = sorted(lint.CONFIG_DEFINITIONS.glob("*.cpp"))
        self.assertTrue(sources, "the Config definition directory moved")
        covered = lint.cir_reset_keys(lint.read(lint.BRIDGE), "\n".join(lint.read(path) for path in sources))
        self.assertIn("MAIN_CIR_PIC_LOADSTORE", covered)
        self.assertIn("MAIN_CIR_SPECIALIZED_OPS_VALIDATE", covered)
        self.assertNotIn("MAIN_SLOT_B", covered)


class GlobalResetScopeTests(unittest.TestCase):
    def result(self, source):
        with tempfile.TemporaryDirectory() as folder:
            bridge = Path(folder) / "bridge.mm"
            bridge.write_text(source)
            with patch.object(lint, "BRIDGE", str(bridge)), patch.object(lint, "CONFIG_DEFINITIONS", Path(folder)), contextlib.redirect_stdout(io.StringIO()):
                return lint.main()

    def test_direct_base_setter_is_a_write_not_reset_coverage(self):
        self.assertEqual(self.result('+ (void)setMainAutoDiscChange:(bool)v { Config::SetBase(Config::MAIN_AUTO_DISC_CHANGE, v); }'), 1)

    def test_setter_base_write_cannot_cover_its_own_reset_gap(self):
        self.assertEqual(self.result('+ (void)setFlag:(bool)v { Config::SetBaseOrCurrent(Config::MAIN_ENABLE_CHEATS, v); Config::SetBase(Config::MAIN_ENABLE_CHEATS, v); }'), 1)

    def test_page_reset_cannot_cover_a_global_reset_gap(self):
        self.assertEqual(self.result('+ (void)setFlag:(bool)v { Config::SetBaseOrCurrent(Config::MAIN_ENABLE_CHEATS, v); } + (void)resetPage { safe_delete(Config::MAIN_ENABLE_CHEATS); }'), 1)

    def test_comment_cannot_cover_a_global_reset_gap(self):
        self.assertEqual(self.result('+ (void)setFlag:(bool)v { Config::SetBaseOrCurrent(Config::MAIN_ENABLE_CHEATS, v); } + (void)resetGameplayConfigKeys { /* del(Config::MAIN_ENABLE_CHEATS); */ }'), 1)

    def test_global_delete_covers_the_ui_setter(self):
        self.assertEqual(self.result('+ (void)setFlag:(bool)v { Config::SetBaseOrCurrent(Config::MAIN_ENABLE_CHEATS, v); } + (void)resetGameplayConfigKeys { del(Config::MAIN_ENABLE_CHEATS); }'), 0)

    def test_preserved_sd_write_protection_needs_no_reset(self):
        self.assertEqual(self.result('+ (void)setMainAllowSDWrites:(bool)v { Config::SetBase(Config::MAIN_ALLOW_SD_WRITES, v); }'), 0)

    def test_dynamic_controller_accessor_is_not_a_phantom_setting_g(self):
        self.assertEqual(self.result('+ (void)setPort:(int)v { Config::SetBaseOrCurrent(Config::GetInfoForSIDevice(port), v); }'), 0)


if __name__ == "__main__":
    unittest.main()
