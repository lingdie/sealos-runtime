package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"

	yamlv3 "gopkg.in/yaml.v3"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	kubeproxyconfig "k8s.io/kube-proxy/config/v1alpha1"
	kubeletconfig "k8s.io/kubelet/config/v1beta1"
)

const helperAPIVersion = "v1"

var schemaByKind = map[string]*schemaNode{
	"KubeletConfiguration":    buildSchema(reflect.TypeOf(kubeletconfig.KubeletConfiguration{})),
	"KubeProxyConfiguration":  buildSchema(reflect.TypeOf(kubeproxyconfig.KubeProxyConfiguration{})),
	"ClusterConfiguration":    nil,
	"InitConfiguration":       nil,
	"JoinConfiguration":       nil,
	"UpgradeConfiguration":    nil,
	"ResetConfiguration":      nil,
	"ClusterStatus":           nil,
	"DNSAddOn":                nil,
	"BootstrapToken":          nil,
	"Output":                  nil,
	"APIEndpoint":             nil,
	"NodeRegistrationOptions": nil,
}

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
		out, err := sanitizeKubeadmConfig(raw)
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

func sanitizeKubeadmConfig(raw []byte) ([]byte, error) {
	decoder := yamlv3.NewDecoder(bytes.NewReader(raw))
	docs := make([]*yamlv3.Node, 0)
	for {
		var doc yamlv3.Node
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
		if err := sanitizeDocument(&doc); err != nil {
			return nil, err
		}
		docs = append(docs, &doc)
	}
	if len(docs) == 0 {
		return raw, nil
	}

	var out bytes.Buffer
	encoder := yamlv3.NewEncoder(&out)
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

func sanitizeDocument(doc *yamlv3.Node) error {
	mapping := documentMapping(doc)
	if mapping == nil {
		return nil
	}

	kind := scalarValue(mapping, "kind")
	schema, ok := schemaByKind[kind]
	if !ok || schema == nil {
		return nil
	}
	if err := pruneUnknownFields(mapping, schema); err != nil {
		return fmt.Errorf("sanitize %s: %w", kind, err)
	}
	return nil
}

type schemaNode struct {
	fields      map[string]*schemaNode
	preserveMap bool
}

func buildSchema(t reflect.Type) *schemaNode {
	t = dereferenceType(t)
	if t.Kind() != reflect.Struct {
		return &schemaNode{preserveMap: true}
	}

	schema := &schemaNode{fields: map[string]*schemaNode{}}
	for i := 0; i < t.NumField(); i++ {
		field := t.Field(i)
		if field.PkgPath != "" {
			continue
		}
		jsonTag := field.Tag.Get("json")
		if jsonTag == "-" {
			continue
		}
		if isInlineField(jsonTag) {
			mergeInlineSchema(schema, buildSchema(field.Type))
			continue
		}
		name := jsonFieldName(field)
		if name == "" {
			continue
		}
		schema.fields[name] = buildFieldSchema(field.Type)
	}
	return schema
}

func buildFieldSchema(t reflect.Type) *schemaNode {
	t = dereferenceType(t)
	switch t.Kind() {
	case reflect.Struct:
		if t == reflect.TypeOf(metav1.Duration{}) || t.PkgPath() == "time" {
			return &schemaNode{preserveMap: true}
		}
		return buildSchema(t)
	case reflect.Slice, reflect.Array:
		return buildFieldSchema(t.Elem())
	case reflect.Map:
		return &schemaNode{preserveMap: true}
	default:
		return &schemaNode{preserveMap: true}
	}
}

func dereferenceType(t reflect.Type) reflect.Type {
	for t.Kind() == reflect.Ptr {
		t = t.Elem()
	}
	return t
}

func isInlineField(jsonTag string) bool {
	if jsonTag == ",inline" {
		return true
	}
	for _, part := range strings.Split(jsonTag, ",") {
		if part == "inline" {
			return true
		}
	}
	return false
}

func mergeInlineSchema(dst, src *schemaNode) {
	if dst == nil || src == nil {
		return
	}
	if dst.fields == nil {
		dst.fields = map[string]*schemaNode{}
	}
	for name, child := range src.fields {
		dst.fields[name] = child
	}
}

func jsonFieldName(field reflect.StructField) string {
	tag := field.Tag.Get("json")
	if tag == "" {
		return field.Name
	}
	name, _, _ := strings.Cut(tag, ",")
	return name
}

func pruneUnknownFields(node *yamlv3.Node, schema *schemaNode) error {
	if node == nil || schema == nil || schema.preserveMap {
		return nil
	}

	if node.Kind == yamlv3.SequenceNode {
		for _, item := range node.Content {
			if err := pruneUnknownFields(item, schema); err != nil {
				return err
			}
		}
		return nil
	}

	if node.Kind != yamlv3.MappingNode {
		return nil
	}

	out := node.Content[:0]
	for i := 0; i+1 < len(node.Content); i += 2 {
		key := node.Content[i]
		value := node.Content[i+1]
		childSchema, ok := schema.fields[key.Value]
		if !ok {
			continue
		}
		if err := pruneUnknownFields(value, childSchema); err != nil {
			return err
		}
		out = append(out, key, value)
	}
	node.Content = out
	return nil
}

func isEmptyDocument(doc *yamlv3.Node) bool {
	if doc.Kind == 0 {
		return true
	}
	if doc.Kind == yamlv3.DocumentNode && len(doc.Content) == 0 {
		return true
	}
	if doc.Kind == yamlv3.DocumentNode && len(doc.Content) == 1 {
		return doc.Content[0].Kind == yamlv3.ScalarNode && doc.Content[0].Value == ""
	}
	return false
}

func documentMapping(doc *yamlv3.Node) *yamlv3.Node {
	if doc.Kind == yamlv3.DocumentNode {
		if len(doc.Content) == 0 {
			return nil
		}
		doc = doc.Content[0]
	}
	if doc.Kind != yamlv3.MappingNode {
		return nil
	}
	return doc
}

func scalarValue(mapping *yamlv3.Node, key string) string {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			return mapping.Content[i+1].Value
		}
	}
	return ""
}
