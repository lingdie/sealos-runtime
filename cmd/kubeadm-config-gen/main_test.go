package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestSanitizePre130RemovesNewerKubeletAndKubeProxyFields(t *testing.T) {
	input := []byte(`apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
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

	got, err := sanitizeKubeadmConfig(input, "v1.27.16")
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
	for _, want := range []string{"format: text", "json:", "maxPerCore"} {
		if !strings.Contains(string(got), want) {
			t.Fatalf("expected %q to be preserved:\n%s", want, got)
		}
	}
}

func TestSanitize130KeepsConfigUnchanged(t *testing.T) {
	input := []byte(`apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
nftables:
  masqueradeBit: 14
`)

	got, err := sanitizeKubeadmConfig(input, "v1.30.0")
	if err != nil {
		t.Fatalf("sanitizeKubeadmConfig() error = %v", err)
	}
	if !bytes.Equal(got, input) {
		t.Fatalf("expected v1.30 config to be unchanged:\n%s", got)
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
