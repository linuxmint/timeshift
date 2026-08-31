// Package distro identifies a Linux distribution.
//
// It takes a root path rather than always reading /etc, because the same code
// has to name the distribution INSIDE a snapshot as well as the running one:
// the snapshot listing shows which system each snapshot came from, and a
// cross-distribution restore needs to know what it is restoring.
package distro

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// Info is what could be learned about a distribution.
type Info struct {
	ID          string // ubuntu, debian, fedora, arch
	Release     string // 26.04
	Codename    string // resolute
	Description string // Ubuntu 26.04.1 LTS
}

// FullName is the string recorded in a snapshot's control file, matching
// LinuxDistro.full_name(): the description, then the codename in parentheses.
func (i Info) FullName() string {
	parts := []string{}
	if i.Description != "" {
		parts = append(parts, i.Description)
	}
	if i.Codename != "" {
		parts = append(parts, "("+i.Codename+")")
	}
	return strings.Join(parts, " ")
}

// Type buckets a distribution into the family whose tools a restore must use --
// which update-grub, which initramfs generator. Runtime feature detection is
// preferred where possible; this is for the cases where it is not.
func (i Info) Type() string {
	switch strings.ToLower(i.ID) {
	case "fedora", "rhel", "rocky", "centos", "almalinux":
		return "redhat"
	case "manjaro", "arch":
		return "arch"
	case "ubuntu", "debian", "linuxmint", "pop":
		return "debian"
	default:
		return ""
	}
}

// Detect reads the distribution under root. Pass "/" for the running system.
//
// lsb-release is tried first and os-release second, matching
// LinuxDistro.get_dist_info(): where both exist they agree, and where they
// disagree lsb-release is the more specific.
func Detect(root string) Info {
	var info Info

	if kv := readKeyValues(filepath.Join(root, "etc/lsb-release")); len(kv) > 0 {
		info.ID = kv["DISTRIB_ID"]
		info.Release = kv["DISTRIB_RELEASE"]
		info.Codename = kv["DISTRIB_CODENAME"]
		info.Description = kv["DISTRIB_DESCRIPTION"]
	}

	if info.Description == "" || info.ID == "" {
		kv := readKeyValues(filepath.Join(root, "etc/os-release"))
		if info.ID == "" {
			info.ID = kv["ID"]
		}
		if info.Release == "" {
			info.Release = kv["VERSION_ID"]
		}
		if info.Codename == "" {
			info.Codename = kv["VERSION_CODENAME"]
		}
		if info.Description == "" {
			info.Description = kv["PRETTY_NAME"]
		}
	}

	return info
}

// readKeyValues parses a KEY=value file, stripping surrounding quotes.
func readKeyValues(path string) map[string]string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()

	out := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		// Both quoting styles occur; os-release uses double quotes, some
		// derivatives use single.
		if len(value) >= 2 {
			if (value[0] == '"' && value[len(value)-1] == '"') ||
				(value[0] == '\'' && value[len(value)-1] == '\'') {
				value = value[1 : len(value)-1]
			}
		}
		out[strings.TrimSpace(key)] = value
	}
	return out
}
