package packaging_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func fixture(t *testing.T) string {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("macOS packaging tools")
	}
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "scripts"), 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"build-go-preview.sh", "verify-go-preview.sh"} {
		data, err := os.ReadFile(filepath.Join("..", "..", "scripts", name))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "scripts", name), data, 0700); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func rejected(t *testing.T, root, script, reason string) {
	t.Helper()
	cmd := exec.Command("/bin/zsh", filepath.Join(root, "scripts", script))
	output, err := cmd.CombinedOutput()
	if err == nil || !strings.Contains(string(output), reason) {
		t.Fatalf("expected rejection %q; error=%v, output=%s", reason, err, output)
	}
}

func TestBuildRejectsLinkedDistributionDirectory(t *testing.T) {
	root := fixture(t)
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "dist")); err != nil {
		t.Fatal(err)
	}
	rejected(t, root, "build-go-preview.sh", "dist must be a real directory")
	entries, err := os.ReadDir(outside)
	if err != nil || len(entries) != 0 {
		t.Fatal("linked destination was modified")
	}
}

func TestBuildRejectsUnownedPreviewDirectory(t *testing.T) {
	root := fixture(t)
	if err := os.MkdirAll(filepath.Join(root, "dist", "GoPreview"), 0700); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(root, "dist", "GoPreview", "synthetic-user-file")
	if err := os.WriteFile(sentinel, []byte("preserve"), 0600); err != nil {
		t.Fatal(err)
	}
	rejected(t, root, "build-go-preview.sh", "preview directory is not owned by this builder")
	if content, err := os.ReadFile(sentinel); err != nil || string(content) != "preserve" {
		t.Fatal("unowned destination was modified")
	}
}

func TestBuildRejectsLinkedAppWithoutTouchingTarget(t *testing.T) {
	root := fixture(t)
	preview := filepath.Join(root, "dist", "GoPreview")
	if err := os.MkdirAll(preview, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(preview, ".kinlogue-go-preview-owner"), []byte("kinlogue-go-preview-v1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(preview, "KinlogueGoPreview.app")); err != nil {
		t.Fatal(err)
	}
	rejected(t, root, "build-go-preview.sh", "app target must be a real directory")
	entries, err := os.ReadDir(outside)
	if err != nil || len(entries) != 0 {
		t.Fatal("linked app target was modified")
	}
}

func TestVerifierRefusesMissingApp(t *testing.T) {
	root := fixture(t)
	rejected(t, root, "verify-go-preview.sh", "preview bundle is missing or linked")
}

// This is an inert copy of a system binary, never launched. Real codesign and
// plutil exercise the verifier's rejection path before Go build-info checks.
func signedFixture(t *testing.T, editEntitlements func(string) string) (string, string) {
	t.Helper()
	root := fixture(t)
	app := filepath.Join(root, "dist", "GoPreview", "KinlogueGoPreview.app")
	for _, pair := range [][2]string{
		{"Info.plist", "Contents/Info.plist"},
		{"en.lproj/InfoPlist.strings", "Contents/Resources/en.lproj/InfoPlist.strings"},
		{"zh-Hans.lproj/InfoPlist.strings", "Contents/Resources/zh-Hans.lproj/InfoPlist.strings"},
	} {
		data, err := os.ReadFile(pair[0])
		if err != nil {
			t.Fatal(err)
		}
		for _, path := range []string{filepath.Join(root, "packaging", "go-preview", pair[0]), filepath.Join(app, pair[1])} {
			if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	for _, path := range []string{filepath.Join(root, "LICENSE"), filepath.Join(app, "Contents", "Resources", "LICENSE")} {
		if err := os.WriteFile(path, []byte("synthetic license"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	binary, err := os.ReadFile("/usr/bin/true")
	if err != nil {
		t.Fatal(err)
	}
	binDir := filepath.Join(app, "Contents", "MacOS")
	if err := os.MkdirAll(binDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(binDir, "KinlogueGoPreview"), binary, 0700); err != nil {
		t.Fatal(err)
	}
	entitlements, err := os.ReadFile("Entitlements.plist")
	if err != nil {
		t.Fatal(err)
	}
	if editEntitlements != nil {
		entitlements = []byte(editEntitlements(string(entitlements)))
	}
	entitlementsPath := filepath.Join(root, "synthetic-entitlements.plist")
	if err := os.WriteFile(entitlementsPath, entitlements, 0600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlementsPath, app).CombinedOutput(); err != nil {
		t.Fatalf("sign synthetic app: %v: %s", err, output)
	}
	return root, app
}

const entitlementContract = "entitlements must be exactly sandbox, user-selected read-write and network server"

func TestVerifierRejectsAdditionalNetworkEntitlement(t *testing.T) {
	root, _ := signedFixture(t, func(e string) string {
		return strings.Replace(e, "</dict>", "<key>com.apple.security.network.client</key><true/></dict>", 1)
	})
	rejected(t, root, "verify-go-preview.sh", entitlementContract)
}

// Phone upload needs the inbound server entitlement; a current bundle without
// it would build but could never accept a phone connection.
func TestVerifierRequiresNetworkServerEntitlement(t *testing.T) {
	root, _ := signedFixture(t, func(e string) string {
		return strings.Replace(e, "<key>com.apple.security.network.server</key><true/>", "", 1)
	})
	rejected(t, root, "verify-go-preview.sh", entitlementContract)
}

func TestVerifierRejectsUnexpectedHelper(t *testing.T) {
	root, app := signedFixture(t, nil)
	if err := os.WriteFile(filepath.Join(app, "Contents", "MacOS", "acceptance-helper"), []byte("synthetic"), 0600); err != nil {
		t.Fatal(err)
	}
	rejected(t, root, "verify-go-preview.sh", "bundle contains an unexpected file or helper")
}
