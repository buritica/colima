//go:build darwin

package lima

import (
	"context"
	"runtime"
	"strings"
	"testing"

	"github.com/abiosoft/colima/config"
	"github.com/abiosoft/colima/environment/vm/lima/limaconfig"
	"github.com/abiosoft/colima/util/fsutil"
	"gopkg.in/yaml.v3"
)

// Tests for VZ + virtiofs config generation. Added while investigating
// a zombie-container regression seen with colima 0.10.1 + lima 2.1.x on
// macOS 26.x. Container processes doing I/O on virtiofs-backed bind mounts
// entered uninterruptible D-state and could not be SIGKILLed.
//
// See: https://github.com/abiosoft/colima/issues/1552

func Test_newConf_VZ_Virtiofs_SchemaShape(t *testing.T) {
	if runtime.GOARCH != "arm64" {
		t.Skip("VZ+virtiofs+rosetta path requires Apple Silicon")
	}
	fsutil.FS = fsutil.FakeFS

	conf := config.Config{
		VMType:    limaconfig.VZ,
		MountType: limaconfig.VIRTIOFS,
		VZRosetta: true,
		CPU:       4,
		Memory:    8,
		Mounts:    []config.Mount{{Location: "~", Writable: true}},
	}
	got, err := newConf(context.Background(), conf)
	if err != nil {
		t.Fatalf("newConf: %v", err)
	}

	// Schema contract lima 2.x enforces: rosetta must live at
	// vmOpts.vz.rosetta, NOT at top-level `rosetta:`. Colima 0.9.x wrote the
	// older flat schema, which lima 2.x would flag with a Non-strict YAML
	// warning. Downgrading lima without downgrading colima will fail
	// because of this placement. Pin this shape.
	out, err := yaml.Marshal(got)
	if err != nil {
		t.Fatalf("yaml.Marshal: %v", err)
	}
	y := string(out)

	// Must have the nested form.
	if !strings.Contains(y, "vmOpts:") {
		t.Errorf("generated yaml missing `vmOpts:` key; got:\n%s", y)
	}
	// The string "rosetta" should appear under vmOpts.vz, not at top-level.
	// Top-level `rosetta:` (at column 0) is the lima 1.x schema and will
	// break on lima 2.x.
	for _, line := range strings.Split(y, "\n") {
		if line == "rosetta:" {
			t.Errorf("top-level `rosetta:` found: this is lima 1.x schema "+
				"and will warn on lima 2.x. Expected nested under vmOpts.vz. "+
				"yaml:\n%s", y)
		}
	}

	// The Rosetta struct should have the nested path populated.
	if !got.VMOpts.VZOpts.Rosetta.Enabled && !got.VMOpts.VZOpts.Rosetta.BinFmt {
		// Rosetta may be disabled if Rosetta2 isn't installed on the host;
		// that's fine — test only asserts the struct path exists.
		t.Logf("Rosetta not enabled (likely Rosetta2 not installed on host)")
	}
}

func Test_newConf_VZ_ImpliesVirtiofs(t *testing.T) {
	fsutil.FS = fsutil.FakeFS

	// When VMType is VZ and MountType is unset, colima should default to
	// virtiofs. This has been the contract since VZ support was added.
	conf := config.Config{
		VMType: limaconfig.VZ,
		CPU:    4,
		Memory: 8,
		Mounts: []config.Mount{{Location: "/tmp/test", Writable: true}},
	}
	got, err := newConf(context.Background(), conf)
	if err != nil {
		t.Fatalf("newConf: %v", err)
	}

	// Only assert the MountType default when VZ was actually selected.
	// On intel macs or older macOS, the VZ path is skipped and VMType
	// falls back to QEMU → 9p.
	if got.VMType == limaconfig.VZ {
		if got.MountType != limaconfig.VIRTIOFS {
			t.Errorf("VZ should default to virtiofs mount type; got %q", got.MountType)
		}
	}
}

// Test_Mount_VirtiofsOptions_NotExposed documents a known limitation relevant
// to the zombie-container investigation. Lima supports virtiofs mount options
// (cache mode, queue size, etc.) but colima's Mount struct does not pass any
// through — every virtiofs mount uses lima's defaults.
//
// If lima 2.x changed virtiofs defaults in a way that breaks signal delivery
// for D-state processes, colima has no user-facing escape hatch other than
// switching mount type. This test exists to surface that fact in code
// (rather than only in a github issue) so future contributors see it.
func Test_Mount_VirtiofsOptions_NotExposed(t *testing.T) {
	var m limaconfig.Mount
	// Mount exposes NineP options (9p) but no Virtiofs options. If lima adds
	// a Virtiofs struct to its Mount type and colima mirrors it here, this
	// test can be flipped to assert the opposite.
	_ = m.NineP
	// No m.Virtiofs field — intentional documentation.
}
