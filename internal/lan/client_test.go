package lan

import (
	"os/exec"
	"testing"
)

// This harness runs the actual embedded client with synthetic DOM/XHR events.
// Node is a test-only prerequisite; it is not part of the application bundle.
func TestPhoneClientRetryOrdering(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node.js unavailable; offline JavaScript event-order harness not run")
	}
	for _, mode := range []string{"delayed", "synchronous"} {
		t.Run(mode, func(t *testing.T) {
			output, err := exec.Command(node, "testdata/client_retry.cjs", "assets/app.js", mode).CombinedOutput()
			if err != nil {
				t.Fatalf("phone client retry: %v\n%s", err, output)
			}
		})
	}
}
