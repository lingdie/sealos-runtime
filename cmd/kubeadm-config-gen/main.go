package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

const helperAPIVersion = "v1"

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "kubeadm-config-gen: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New("missing command")
	}

	switch args[0] {
	case "sanitize":
		fs := flag.NewFlagSet("sanitize", flag.ContinueOnError)
		fs.SetOutput(io.Discard)
		kubernetesVersion := fs.String("kubernetes-version", "", "Kubernetes version")
		apiVersion := fs.String("helper-api", helperAPIVersion, "helper API version")
		if err := fs.Parse(args[1:]); err != nil {
			return err
		}
		if *apiVersion != helperAPIVersion {
			return fmt.Errorf("unsupported helper API %q", *apiVersion)
		}
		if *kubernetesVersion == "" {
			return errors.New("--kubernetes-version is required")
		}
		raw, err := io.ReadAll(stdin)
		if err != nil {
			return err
		}
		out, err := sanitizeKubeadmConfig(raw, *kubernetesVersion)
		if err != nil {
			return err
		}
		_, err = stdout.Write(out)
		return err
	case "version":
		_, err := fmt.Fprintln(stdout, helperAPIVersion)
		return err
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func sanitizeKubeadmConfig(raw []byte, kubernetesVersion string) ([]byte, error) {
	minor, err := kubernetesMinor(kubernetesVersion)
	if err != nil {
		return nil, err
	}
	if minor >= 30 {
		return raw, nil
	}

	decoder := yaml.NewDecoder(bytes.NewReader(raw))
	docs := make([]*yaml.Node, 0)
	for {
		var doc yaml.Node
		err := decoder.Decode(&doc)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if isEmptyDocument(&doc) {
			continue
		}
		sanitizeDocument(&doc)
		docs = append(docs, &doc)
	}
	if len(docs) == 0 {
		return raw, nil
	}

	var out bytes.Buffer
	encoder := yaml.NewEncoder(&out)
	encoder.SetIndent(2)
	for _, doc := range docs {
		if err := encoder.Encode(doc); err != nil {
			_ = encoder.Close()
			return nil, err
		}
	}
	if err := encoder.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func kubernetesMinor(version string) (int, error) {
	version = strings.TrimPrefix(strings.TrimSpace(version), "v")
	parts := strings.Split(version, ".")
	if len(parts) < 2 {
		return 0, fmt.Errorf("invalid Kubernetes version %q", version)
	}
	if parts[0] != "1" {
		return 0, fmt.Errorf("unsupported Kubernetes major version %q", parts[0])
	}
	minor, err := strconv.Atoi(parts[1])
	if err != nil {
		return 0, fmt.Errorf("invalid Kubernetes minor version %q: %w", parts[1], err)
	}
	return minor, nil
}

func sanitizeDocument(doc *yaml.Node) {
	mapping := documentMapping(doc)
	if mapping == nil {
		return
	}

	switch scalarValue(mapping, "kind") {
	case "KubeletConfiguration":
		deleteMappingKeys(mapping,
			"containerLogMaxWorkers",
			"containerLogMonitorInterval",
			"imageMaximumGCAge",
			"podLogsDir",
		)
		deleteNestedMappingKey(mapping, "logging", "options", "text")
	case "KubeProxyConfiguration":
		deleteMappingKeys(mapping, "logging", "nftables")
		deleteNestedMappingKey(mapping, "conntrack", "tcpBeLiberal")
		deleteNestedMappingKey(mapping, "conntrack", "udpStreamTimeout")
		deleteNestedMappingKey(mapping, "conntrack", "udpTimeout")
	}
}

func isEmptyDocument(doc *yaml.Node) bool {
	if doc.Kind == 0 {
		return true
	}
	if doc.Kind == yaml.DocumentNode && len(doc.Content) == 0 {
		return true
	}
	if doc.Kind == yaml.DocumentNode && len(doc.Content) == 1 {
		return doc.Content[0].Kind == yaml.ScalarNode && doc.Content[0].Value == ""
	}
	return false
}

func documentMapping(doc *yaml.Node) *yaml.Node {
	if doc.Kind == yaml.DocumentNode {
		if len(doc.Content) == 0 {
			return nil
		}
		doc = doc.Content[0]
	}
	if doc.Kind != yaml.MappingNode {
		return nil
	}
	return doc
}

func scalarValue(mapping *yaml.Node, key string) string {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			return mapping.Content[i+1].Value
		}
	}
	return ""
}

func deleteMappingKeys(mapping *yaml.Node, keys ...string) {
	wanted := make(map[string]struct{}, len(keys))
	for _, key := range keys {
		wanted[key] = struct{}{}
	}

	out := mapping.Content[:0]
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if _, ok := wanted[mapping.Content[i].Value]; ok {
			continue
		}
		out = append(out, mapping.Content[i], mapping.Content[i+1])
	}
	mapping.Content = out
}

func deleteNestedMappingKey(mapping *yaml.Node, keys ...string) {
	if len(keys) == 0 {
		return
	}
	current := mapping
	for _, key := range keys[:len(keys)-1] {
		current = mappingValue(current, key)
		if current == nil || current.Kind != yaml.MappingNode {
			return
		}
	}
	deleteMappingKeys(current, keys[len(keys)-1])
}

func mappingValue(mapping *yaml.Node, key string) *yaml.Node {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			return mapping.Content[i+1]
		}
	}
	return nil
}
