import importlib.util
import pathlib
import plistlib
import re
import sys
import tempfile
import unittest


REPOSITORY = pathlib.Path(__file__).parents[2]
SCRIPT = REPOSITORY / "scripts/check_bundle_entitlements.py"
SPEC = importlib.util.spec_from_file_location("check_bundle_entitlements", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
checker = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = checker
SPEC.loader.exec_module(checker)

PROFILE_SCRIPT = REPOSITORY / "scripts/profile_backed_entitlements.py"
PROFILE_SPEC = importlib.util.spec_from_file_location("profile_backed_entitlements", PROFILE_SCRIPT)
assert PROFILE_SPEC is not None and PROFILE_SPEC.loader is not None
profile_backing = importlib.util.module_from_spec(PROFILE_SPEC)
sys.modules[PROFILE_SPEC.name] = profile_backing
PROFILE_SPEC.loader.exec_module(profile_backing)


class BundleEntitlementTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        self.bundle = self.root / "Threading.app"
        self.helpers = self.bundle / "Contents/Helpers"
        self.helpers.mkdir(parents=True)
        self.observed = {}

        for name, relative_path in checker.HELPER_ENTITLEMENTS.items():
            declaration = self.root / relative_path
            declaration.parent.mkdir(parents=True, exist_ok=True)
            value = (
                {"com.apple.security.app-sandbox": True}
                if name == "threading-extension-helper"
                else {}
            )
            declaration.write_bytes(plistlib.dumps(value))
            binary = self.helpers / name
            binary.touch()
            binary.chmod(0o755)
            self.observed[name] = value

        scc = self.helpers / "scc"
        scc.touch()
        scc.chmod(0o755)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def signed_reader(self, binary: pathlib.Path):
        return self.observed[binary.name]

    def test_exact_helper_entitlements_pass(self) -> None:
        self.assertEqual(
            checker.verify_bundle(self.bundle, self.root, self.signed_reader),
            [],
        )

    def test_profile_prefix_is_expanded_before_comparing_signed_values(self) -> None:
        declaration = self.root / checker.HELPER_ENTITLEMENTS["threading-triggerd"]
        declaration.write_bytes(
            plistlib.dumps(
                {
                    "keychain-access-groups": [
                        "$(AppIdentifierPrefix)codes.threading.triggers"
                    ]
                }
            )
        )
        self.observed["threading-triggerd"] = {
            "keychain-access-groups": ["SMQ3E8Y57T.codes.threading.triggers"]
        }

        problems = checker.verify_bundle(
            self.bundle,
            self.root,
            self.signed_reader,
            {"AppIdentifierPrefix": "SMQ3E8Y57T."},
        )

        self.assertEqual(problems, [])

    def test_app_entitlements_on_a_sandboxed_helper_fail(self) -> None:
        self.observed["threading-extension-helper"] = {
            "com.apple.security.cs.allow-unsigned-executable-memory": True,
            "com.apple.security.cs.disable-library-validation": True,
        }

        problems = checker.verify_bundle(self.bundle, self.root, self.signed_reader)

        self.assertEqual(len(problems), 1)
        self.assertIn("missing com.apple.security.app-sandbox", problems[0])
        self.assertIn("unexpected com.apple.security.cs.allow-unsigned-executable-memory", problems[0])

    def test_new_unmapped_helper_fails_closed(self) -> None:
        binary = self.helpers / "threading-new-helper"
        binary.touch()
        binary.chmod(0o755)

        problems = checker.verify_bundle(self.bundle, self.root, self.signed_reader)

        self.assertIn(
            "threading-new-helper: executable has no entitlement declaration in the verifier",
            problems,
        )

    def test_manifest_matches_project_entitlement_declarations(self) -> None:
        project = (REPOSITORY / "Threading.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        for declaration in checker.HELPER_ENTITLEMENTS.values():
            self.assertTrue((REPOSITORY / declaration).is_file())
            self.assertIn(f'CODE_SIGN_ENTITLEMENTS = "{declaration}";', project)

    def test_every_helper_declaration_in_the_project_is_registered(self) -> None:
        """A helper target added under Targets/ has to join the verifier.

        The other direction alone let `threading-triggerd` ship a declaration the verifier had
        never heard of: the manifest listed only files that exist, so nothing noticed the helper
        that existed without a manifest entry. That is found at build time — the verifier fails
        closed on an unknown executable in Contents/Helpers — which means it is found after a
        Release build rather than here.
        """
        project = (REPOSITORY / "Threading.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        declared = {
            pathlib.Path(match)
            for match in re.findall(
                r'CODE_SIGN_ENTITLEMENTS = "(Targets/[^"]+\.entitlements)";', project
            )
        }

        self.assertTrue(declared, "no helper entitlement declarations found in the project")
        self.assertEqual(declared - set(checker.HELPER_ENTITLEMENTS.values()), set())

    def test_auto_install_and_release_both_run_the_verifier(self) -> None:
        autoinstall = (REPOSITORY / "scripts/autoinstall.sh").read_text(encoding="utf-8")
        release = (REPOSITORY / "scripts/release.sh").read_text(encoding="utf-8")

        self.assertNotIn("CODE_SIGN_ENTITLEMENTS=", autoinstall)
        self.assertIn("check_bundle_entitlements.py", autoinstall)
        self.assertIn("check_bundle_entitlements.py", release)

    def test_all_profile_backed_entitlement_families_share_one_rule(self) -> None:
        declarations = {
            "com.apple.developer.aps-environment": "production",
            "keychain-access-groups": ["SMQ3E8Y57T.codes.threading.triggers"],
            "com.apple.security.application-groups": ["group.codes.threading"],
            "com.apple.security.cs.disable-library-validation": True,
            "com.apple.security.app-sandbox": True,
        }

        self.assertEqual(
            profile_backing.profile_backed_entitlements(declarations),
            {
                "com.apple.developer.aps-environment",
                "keychain-access-groups",
                "com.apple.security.application-groups",
            },
        )

        autoinstall = (REPOSITORY / "scripts/autoinstall.sh").read_text(encoding="utf-8")
        release = (REPOSITORY / "scripts/release.sh").read_text(encoding="utf-8")
        self.assertIn("from profile_backed_entitlements import", autoinstall)
        self.assertIn("from profile_backed_entitlements import", release)


if __name__ == "__main__":
    unittest.main()
