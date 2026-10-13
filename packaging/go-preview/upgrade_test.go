package packaging_test

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func put(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatal(err)
	}
}

func run(t *testing.T, root, executable string, args ...string) []byte {
	t.Helper()
	cmd := exec.Command(executable, args...)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "GOTOOLCHAIN=local", "GOWORK=off", "GOENV=off", "GOFLAGS=-mod=readonly", "CGO_ENABLED=0")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("synthetic packaging command failed: %v: %s", err, out)
	}
	return out
}

// Build a small, inert Go entry point with real dependency build information.
// It is never launched and does not import Kinlogue's application or data code.
func goFixture(t *testing.T) (string, string) {
	t.Helper()
	root := fixture(t)
	goPath, err := exec.LookPath("go")
	if err != nil {
		t.Fatal(err)
	}
	goPath, err = filepath.Abs(goPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"go.mod", "go.sum", "LICENSE"} {
		data, err := os.ReadFile(filepath.Join("..", "..", name))
		if err != nil {
			t.Fatal(err)
		}
		put(t, filepath.Join(root, name), data, 0600)
	}
	run(t, root, goPath, "mod", "edit", "-dropreplace=github.com/egoist/mygo")
	// Root tidy may omit the replaced module's checksum. The legacy fixture
	// explicitly fetches the locked upstream version into its own go.sum.
	run(t, root, goPath, "mod", "download", "github.com/egoist/mygo@"+mygoPin)
	for _, name := range []string{"Info.plist", "Entitlements.plist", "en.lproj/InfoPlist.strings", "zh-Hans.lproj/InfoPlist.strings"} {
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		put(t, filepath.Join(root, "packaging", "go-preview", name), data, 0600)
	}
	put(t, filepath.Join(root, "cmd", "kinlogue", "main.go"), []byte(`package main
import (
 _ "github.com/egoist/mygo/ui"
 _ "github.com/ebitengine/purego"
 _ "modernc.org/sqlite"
)
func main() {}
`), 0600)
	return root, goPath
}

// mygoPin is the upstream version the preview links through its local
// replacement. Older pins are accepted only for preserving previous bundles.
const mygoPin = "v0.4.8"

func addLocalMygo(t *testing.T, root, goPath, replacement string) {
	t.Helper()
	put(t, filepath.Join(root, replacement, "go.mod"), []byte("module github.com/egoist/mygo\n\ngo 1.27.2\n"), 0600)
	put(t, filepath.Join(root, replacement, "ui", "fixture.go"), []byte("package ui\n"), 0600)
	put(t, filepath.Join(root, replacement, "LICENSE"), []byte("synthetic local replacement license\n"), 0600)
	run(t, root, goPath, "mod", "edit", "-replace=github.com/egoist/mygo=./"+replacement)
}

func sign(t *testing.T, root, app, permission string) {
	t.Helper()
	entitlements, err := os.ReadFile("Entitlements.plist")
	if err != nil {
		t.Fatal(err)
	}
	entitlements = bytes.ReplaceAll(entitlements, []byte("read-only"), []byte(permission))
	entitlements = bytes.ReplaceAll(entitlements, []byte("read-write"), []byte(permission))
	path := filepath.Join(root, "signing.plist")
	put(t, path, entitlements, 0600)
	run(t, root, "/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", path, app)
}

func assembleFixture(t *testing.T, root, goPath, permission string) string {
	t.Helper()
	preview := filepath.Join(root, "dist", "GoPreview")
	app := filepath.Join(preview, "KinlogueGoPreview.app")
	put(t, filepath.Join(preview, ".kinlogue-go-preview-owner"), []byte("kinlogue-go-preview-v1\n"), 0600)
	for source, destination := range map[string]string{
		"packaging/go-preview/Info.plist":                      "Contents/Info.plist",
		"packaging/go-preview/en.lproj/InfoPlist.strings":      "Contents/Resources/en.lproj/InfoPlist.strings",
		"packaging/go-preview/zh-Hans.lproj/InfoPlist.strings": "Contents/Resources/zh-Hans.lproj/InfoPlist.strings",
		"LICENSE": "Contents/Resources/LICENSE",
	} {
		data, err := os.ReadFile(filepath.Join(root, source))
		if err != nil {
			t.Fatal(err)
		}
		put(t, filepath.Join(app, destination), data, 0600)
	}
	executable := filepath.Join(app, "Contents", "MacOS", "KinlogueGoPreview")
	run(t, root, goPath, "build", "-trimpath", "-buildvcs=false", "-tags", "mygo_noinspector", "-o", executable, "./cmd/kinlogue")
	info := run(t, root, goPath, "version", "-m", executable)
	info = info[bytes.IndexByte(info, '\n')+1:]
	resources := filepath.Join(app, "Contents", "Resources")
	put(t, filepath.Join(resources, "BUILD_INFO.txt"), info, 0600)
	for _, line := range strings.Split(string(info), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) >= 4 && fields[1] == "dep" {
			name := strings.ReplaceAll(fields[2], "/", "_") + "@" + fields[3] + ".txt"
			put(t, filepath.Join(resources, "ThirdPartyLicenses", name), []byte("synthetic dependency license\n"), 0600)
		}
	}
	put(t, filepath.Join(resources, "ThirdPartyLicenses", "go1.27.2.txt"), []byte("synthetic runtime license\n"), 0600)
	sign(t, root, app, permission)
	return app
}

func TestBuildPreservesLegacyAppAndUsesSelectedToolchain(t *testing.T) {
	// The earlier bundle was built against the mygo version pinned before,
	// first from upstream and later through the local replacement.
	for _, version := range []string{"v0.2.15", "v0.3.7"} {
		for name, replaced := range map[string]bool{"upstream": false, "local replacement": true} {
			t.Run(version+"/"+name, func(t *testing.T) { buildPreservesLegacyApp(t, version, replaced) })
		}
	}
}

func buildPreservesLegacyApp(t *testing.T, legacyMygoPin string, replaced bool) {
	root, goPath := goFixture(t)
	run(t, root, goPath, "mod", "edit", "-require=github.com/egoist/mygo@"+legacyMygoPin)
	run(t, root, goPath, "mod", "download", "github.com/egoist/mygo@"+legacyMygoPin)
	permission := "read-only"
	if replaced {
		addLocalMygo(t, root, goPath, "third_party/mygo")
		permission = "read-write"
	}
	app := assembleFixture(t, root, goPath, permission)
	original, err := os.ReadFile(filepath.Join(app, "Contents", "MacOS", "KinlogueGoPreview"))
	if err != nil {
		t.Fatal(err)
	}
	run(t, root, goPath, "mod", "edit", "-require=github.com/egoist/mygo@"+mygoPin)
	addLocalMygo(t, root, goPath, "third_party/mygo")
	put(t, filepath.Join(root, "cmd", "kinlogue", "backup.go"), []byte("package main\nimport _ \"filippo.io/age\"\n"), 0600)
	// A setup-go-like directory is deliberately absent from the builder's fixed
	// PATH. The wrapper forwards to the actual pinned compiler, without eval.
	toolBin := filepath.Join(t.TempDir(), "tool cache $(never-execute)", "bin")
	trace := filepath.Join(t.TempDir(), "go-calls")
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }
	wrapper := "#!/bin/zsh\nprint -r -- \"$1\" >> " + quote(trace) + "\nexec " + quote(goPath) + " \"$@\"\n"
	put(t, filepath.Join(toolBin, "go"), []byte(wrapper), 0700)
	cmd := exec.Command("/bin/zsh", filepath.Join(root, "scripts", "build-go-preview.sh"))
	cmd.Env = append(os.Environ(), "PATH="+toolBin+":/usr/bin:/bin", "GOTOOLCHAIN=auto", "GOFLAGS=-mod=mod")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("upgrade failed: %v: %s", err, out)
	}
	called, err := os.ReadFile(trace)
	if err != nil || !strings.Contains(string(called), "build\n") || strings.Count(string(called), "version\n") < 4 {
		t.Fatalf("builder and nested verifiers did not retain the selected compiler: %v %s", err, called)
	}
	run(t, root, "/bin/zsh", filepath.Join(root, "scripts", "verify-go-preview.sh"))
	previous, err := filepath.Glob(filepath.Join(root, "dist", "GoPreview", "Previous.*", "KinlogueGoPreview.app", "Contents", "MacOS", "KinlogueGoPreview"))
	if err != nil || len(previous) != 1 {
		t.Fatalf("expected one preserved earlier bundle: %v %v", previous, err)
	}
	retained, err := os.ReadFile(previous[0])
	if err != nil || !bytes.Equal(original, retained) {
		t.Fatal("the earlier signed binary was not preserved exactly")
	}
	license, err := os.ReadFile(filepath.Join(app, "Contents", "Resources", "ThirdPartyLicenses", "github.com_egoist_mygo@"+mygoPin+".txt"))
	if err != nil || string(license) != "synthetic local replacement license\n" {
		t.Fatalf("local replacement license not included: %v", err)
	}
}

func TestVerifierRejectsUnapprovedReplacement(t *testing.T) {
	root, goPath := goFixture(t)
	addLocalMygo(t, root, goPath, "third_party/unapproved")
	assembleFixture(t, root, goPath, "read-write")
	rejected(t, root, "verify-go-preview.sh", "module replacements differ from the preview contract")
}

func TestCurrentVerifierRejectsLegacyPermission(t *testing.T) {
	root, goPath := goFixture(t)
	assembleFixture(t, root, goPath, "read-only")
	rejected(t, root, "verify-go-preview.sh", entitlementContract)
}

func TestCurrentVerifierRequiresLocalMygo(t *testing.T) {
	root, goPath := goFixture(t)
	assembleFixture(t, root, goPath, "read-write")
	rejected(t, root, "verify-go-preview.sh", "module replacements differ from the preview contract")
}

func TestCurrentVerifierRequiresBackupCrypto(t *testing.T) {
	root, goPath := goFixture(t)
	addLocalMygo(t, root, goPath, "third_party/mygo")
	assembleFixture(t, root, goPath, "read-write")
	rejected(t, root, "verify-go-preview.sh", "backup crypto pin is incorrect")
}

func TestCurrentVerifierRejectsPreviousMygo(t *testing.T) {
	root, goPath := goFixture(t)
	run(t, root, goPath, "mod", "edit", "-require=github.com/egoist/mygo@v0.3.7")
	addLocalMygo(t, root, goPath, "third_party/mygo")
	put(t, filepath.Join(root, "cmd", "kinlogue", "backup.go"), []byte("package main\nimport _ \"filippo.io/age\"\n"), 0600)
	assembleFixture(t, root, goPath, "read-write")
	rejected(t, root, "verify-go-preview.sh", "direct dependency pin is incorrect")
}

func TestBuilderRejectsAdditionalReplacementBeforePublishing(t *testing.T) {
	root, goPath := goFixture(t)
	addLocalMygo(t, root, goPath, "third_party/mygo")
	put(t, filepath.Join(root, "third_party", "other", "go.mod"), []byte("module github.com/ebitengine/purego\n\ngo 1.27.2\n"), 0600)
	run(t, root, goPath, "mod", "edit", "-replace=github.com/ebitengine/purego=./third_party/other")
	rejected(t, root, "build-go-preview.sh", "module replacements differ from the preview contract")
	if _, err := os.Lstat(filepath.Join(root, "dist", "GoPreview", "KinlogueGoPreview.app")); !os.IsNotExist(err) {
		t.Fatal("builder published an app with an additional replacement")
	}
}
