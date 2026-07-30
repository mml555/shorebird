#include "flutter/shell/common/shorebird/shorebird.h"

#include "gtest/gtest.h"

namespace flutter {
namespace testing {
TEST(Shorebird, GetValueFromYamlValueExists) {
  std::string yaml = "appid: com.example.app\nversion: 1.0.0\n";
  std::string key = "appid";
  std::string value = GetValueFromYaml(yaml, key);
  EXPECT_EQ(value, "com.example.app");
}

TEST(Shorebird, GetValueFromYamlValueDoesNotExist) {
  std::string yaml = "appid: com.example.app\nversion: 1.0.0\n";
  std::string key = "appid2";
  std::string value = GetValueFromYaml(yaml, key);
  EXPECT_EQ(value, "");
}

TEST(Shorebird, PatchAssetsPathSitsBesideThePatch) {
  // Derived from the patch file's own directory, because the two
  // ConfigureShorebird() APIs assemble the patch root differently.
  EXPECT_EQ(PatchAssetsPathForPatch(
                "/data/user/0/com.example/files/shorebird_updater/"
                "app-id/patches/3/dlc.vmcode"),
            "/data/user/0/com.example/files/shorebird_updater/"
            "app-id/patches/3/flutter_assets");
}

TEST(Shorebird, PatchAssetsPathIsEmptyWithoutAPatch) {
  // No active patch means no overlay, and RunConfiguration must leave asset
  // resolution exactly as a stock build has it.
  EXPECT_EQ(PatchAssetsPathForPatch(""), "");
}
}  // namespace testing
}  // namespace flutter