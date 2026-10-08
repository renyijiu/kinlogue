package packaging_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"kinlogue/internal/backup"
)

func privacyFixture(t *testing.T) string {
	t.Helper()
	root := fixture(t)
	for _, name := range []string{"README.md", "PRIVACY.md", ".gitignore", "scripts/privacy-guard.sh", "scripts/privacy-history-guard.sh", "scripts/privacy-history-media-digests.txt"} {
		data, err := os.ReadFile(filepath.Join("..", "..", name))
		if err != nil {
			t.Fatal(err)
		}
		put(t, filepath.Join(root, name), data, 0600)
	}
	for _, name := range []string{"KinlogueDICOMTestSupport", "KinlogueDICOMAcceptanceFixtureGenerator"} {
		put(t, filepath.Join(root, "Sources", name, "Fixture.swift"), []byte("// Synthetic fixture generator.\n"), 0600)
	}
	return root
}

func privacyGit(t *testing.T, root string, args ...string) []byte {
	t.Helper()
	cmd := exec.Command("/usr/bin/git", append([]string{"-c", "core.excludesFile=/dev/null", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false"}, args...)...)
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=Kinlogue Synthetic Test", "GIT_AUTHOR_EMAIL=synthetic@example.invalid", "GIT_COMMITTER_NAME=Kinlogue Synthetic Test", "GIT_COMMITTER_EMAIL=synthetic@example.invalid")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatal("synthetic privacy repository command failed")
	}
	return output
}

func checkPrivacyGuard(t *testing.T, root, script, secret, reason string) {
	t.Helper()
	cmd := exec.Command("/bin/zsh", filepath.Join(root, "scripts", script))
	output, err := cmd.CombinedOutput()
	if secret != "" && strings.Contains(string(output), secret) {
		t.Fatal("privacy guard disclosed the recovery code")
	}
	if reason == "" {
		if err != nil {
			t.Fatal("clean synthetic privacy fixture was rejected")
		}
	} else if err == nil || !strings.Contains(string(output), reason) {
		t.Fatal("privacy guard did not reject the expected artifact category")
	}
}

func TestPrivacyGuardsRejectGoBackupAndRecoveryCodes(t *testing.T) {
	code, err := backup.NewCode()
	if err != nil {
		t.Fatal("synthetic code generation failed")
	}
	for _, sample := range []struct{ name, path, content, reason string }{
		{"backup", "synthetic.kinloguegobackup", "synthetic encrypted container", "backup"},
		{"uppercase_code", "synthetic.txt", code, "recovery"},
		{"lowercase_code", "synthetic.txt", strings.ToLower(code), "recovery"},
	} {
		t.Run(sample.name, func(t *testing.T) {
			root := privacyFixture(t)
			checkPrivacyGuard(t, root, "privacy-guard.sh", code, "")
			put(t, filepath.Join(root, sample.path), []byte(sample.content), 0600)
			checkPrivacyGuard(t, root, "privacy-guard.sh", sample.content, sample.reason)
		})
		t.Run(sample.name+"_deleted_history", func(t *testing.T) {
			root := privacyFixture(t)
			privacyGit(t, root, "init", "-b", "main")
			privacyGit(t, root, "add", "README.md", "scripts/privacy-history-guard.sh", "scripts/privacy-history-media-digests.txt")
			privacyGit(t, root, "commit", "-m", "Synthetic baseline")
			checkPrivacyGuard(t, root, "privacy-history-guard.sh", code, "")
			put(t, filepath.Join(root, sample.path), []byte(sample.content), 0600)
			privacyGit(t, root, "add", "-f", sample.path)
			privacyGit(t, root, "commit", "-m", "Synthetic transient artifact")
			privacyGit(t, root, "rm", sample.path)
			privacyGit(t, root, "commit", "-m", "Remove synthetic transient artifact")
			reason := "credential"
			if sample.name == "backup" {
				reason = "backup"
			}
			checkPrivacyGuard(t, root, "privacy-history-guard.sh", sample.content, reason)
		})
	}
}

func TestGoBackupIsIgnored(t *testing.T) {
	root := privacyFixture(t)
	privacyGit(t, root, "init", "-b", "main")
	privacyGit(t, root, "check-ignore", "--no-index", "synthetic.kinloguegobackup")
}
