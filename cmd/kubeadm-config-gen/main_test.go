package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestSanitizeRemovesFieldsUnsupportedByLinkedKubernetesPackages(t *testing.T) {
	input := []byte(`apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
containerLogMaxWorkers: 1
containerLogMonitorInterval: 10s
imageMaximumGCAge: 0s
podLogsDir: /var/log/pods
logging:
  format: text
  options:
    json:
      infoBufferSize: "0"
    text:
      infoBufferSize: "0"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
conntrack:
  maxPerCore: 32768
  tcpBeLiberal: false
  udpStreamTimeout: 0s
  udpTimeout: 0s
logging:
  format: text
nftables:
  masqueradeBit: 14
`)

	got, err := sanitizeKubeadmConfig(input)
	if err != nil {
		t.Fatalf("sanitizeKubeadmConfig() error = %v", err)
	}
	for _, field := range []string{
		"containerLogMaxWorkers",
		"containerLogMonitorInterval",
		"imageMaximumGCAge",
		"podLogsDir",
		"tcpBeLiberal",
		"udpStreamTimeout",
		"udpTimeout",
		"nftables",
	} {
		if strings.Contains(string(got), field) {
			t.Fatalf("expected %q to be removed:\n%s", field, got)
		}
	}
	if strings.Contains(string(got), "\n    text:") {
		t.Fatalf("expected logging.options.text to be removed:\n%s", got)
	}
	for _, want := range []string{"format: text", "json:", "maxPerCore", "containerRuntimeEndpoint"} {
		if !strings.Contains(string(got), want) {
			t.Fatalf("expected %q to be preserved:\n%s", want, got)
		}
	}
}

func TestSanitizePreservesUnknownFieldsForKindsOwnedByKubeadm(t *testing.T) {
	input := []byte(`apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: ClusterConfiguration
certificateValidityPeriod: 876000h
`)

	got, err := sanitizeKubeadmConfig(input)
	if err != nil {
		t.Fatalf("sanitizeKubeadmConfig() error = %v", err)
	}
	if !strings.Contains(string(got), "certificateValidityPeriod") {
		t.Fatalf("expected kubeadm-owned config to be preserved:\n%s", got)
	}
}

func TestRunSanitize(t *testing.T) {
	var out bytes.Buffer
	err := run(
		[]string{"sanitize", "--kubernetes-version", "v1.27.16"},
		strings.NewReader("kind: KubeProxyConfiguration\nnftables: {}\n"),
		&out,
	)
	if err != nil {
		t.Fatalf("run() error = %v", err)
	}
	if strings.Contains(out.String(), "nftables") {
		t.Fatalf("expected nftables to be removed:\n%s", out.String())
	}
}

func TestVersionedHelperLinkedAgainstKubernetes130Keeps130Fields(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell helper test is not supported on windows")
	}
	repoRoot := mustRepoRoot(t)
	tmp := t.TempDir()

	runCommand(t, tmp, "go", "mod", "init", "helper-version-test")
	runCommand(t, tmp, "go", "mod", "edit", "-go=1.22")
	runCommand(t, tmp, "go", "mod", "edit",
		"-require=github.com/lingdie/sealos-runtime@v0.0.0",
		"-replace=github.com/lingdie/sealos-runtime="+repoRoot,
		"-require=k8s.io/kubelet@v0.30.14",
		"-require=k8s.io/kube-proxy@v0.30.14",
		"-require=k8s.io/apimachinery@v0.30.14",
	)

	helper := filepath.Join(tmp, "kubeadm-config-gen")
	runCommand(t, tmp, "go", "build", "-mod=mod", "-o", helper, "github.com/lingdie/sealos-runtime/cmd/kubeadm-config-gen")

	input := `apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
containerLogMaxWorkers: 1
containerLogMonitorInterval: 10s
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
conntrack:
  tcpBeLiberal: false
  udpStreamTimeout: 0s
  udpTimeout: 0s
logging:
  format: text
nftables:
  masqueradeBit: 14
`
	cmd := exec.Command(helper, "sanitize", "--kubernetes-version", "v1.30.14", "--helper-api", "v1")
	cmd.Stdin = strings.NewReader(input)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("helper failed: %v\n%s", err, out)
	}
	for _, field := range []string{
		"containerLogMaxWorkers",
		"containerLogMonitorInterval",
		"tcpBeLiberal",
		"udpStreamTimeout",
		"udpTimeout",
		"logging",
		"nftables",
	} {
		if !strings.Contains(string(out), field) {
			t.Fatalf("expected Kubernetes 1.30 helper to preserve %q:\n%s", field, out)
		}
	}
}

func mustRepoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot determine current test file")
	}
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", ".."))
	if _, err := os.Stat(filepath.Join(root, "go.mod")); err != nil {
		t.Fatalf("cannot locate repo root from %s: %v", root, err)
	}
	return root
}

func runCommand(t *testing.T, dir, name string, args ...string) {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %s failed in %s: %v\n%s", name, strings.Join(args, " "), dir, err, out)
	}
}
