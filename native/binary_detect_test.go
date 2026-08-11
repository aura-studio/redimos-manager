package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// mkBin creates dir/bin/redimos-<version>[<suffix>] and returns its path.
func mkBin(t *testing.T, dir, version, suffix string) string {
	t.Helper()
	binDir := filepath.Join(dir, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(binDir, "redimos-"+version+suffix)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestFindBundledBinary_Found(t *testing.T) {
	dir := t.TempDir()
	// Place whatever this platform's preferred name is (plus .exe on Windows).
	suffix := ""
	if runtime.GOOS == "windows" {
		suffix = ".exe"
	}
	want := mkBin(t, dir, "v2", suffix)
	if got := findBundledBinary(dir, "v2"); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestFindBundledBinary_ExtensionlessAccepted(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("windows prefers .exe first")
	}
	dir := t.TempDir()
	want := mkBin(t, dir, "v1", "")
	if got := findBundledBinary(dir, "v1"); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestFindBundledBinary_VersionIsolated(t *testing.T) {
	dir := t.TempDir()
	suffix := ""
	if runtime.GOOS == "windows" {
		suffix = ".exe"
	}
	mkBin(t, dir, "v1", suffix)
	if got := findBundledBinary(dir, "v2"); got != "" {
		t.Fatalf("v2 should not resolve to the v1 binary, got %q", got)
	}
}

func TestFindBundledBinary_Missing(t *testing.T) {
	dir := t.TempDir()
	if got := findBundledBinary(dir, "v1"); got != "" {
		t.Fatalf("expected empty for missing binary, got %q", got)
	}
}
