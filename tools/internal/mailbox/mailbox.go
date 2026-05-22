package mailbox

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nielsvaes/dcs-sms/tools/internal/fileutil"
	"github.com/nielsvaes/dcs-sms/tools/internal/proto"
)

// Mailbox addresses the dcs-sms folder structure under a Saved Games root.
type Mailbox struct {
	Root string // e.g. C:\Users\X\Saved Games\DCS\dcs-sms
}

// New returns a Mailbox rooted at root. Caller is responsible for ensuring
// the inbox/outbox/state/log subfolders exist.
func New(root string) *Mailbox {
	return &Mailbox{Root: root}
}

func (m *Mailbox) Inbox() string  { return filepath.Join(m.Root, "inbox") }
func (m *Mailbox) Outbox() string { return filepath.Join(m.Root, "outbox") }
func (m *Mailbox) State() string  { return filepath.Join(m.Root, "state") }
func (m *Mailbox) Log() string    { return filepath.Join(m.Root, "log") }

// WriteRequest writes req to inbox/<id>.req.json atomically.
func (m *Mailbox) WriteRequest(req proto.ExecRequest) error {
	if req.ID == "" {
		return errors.New("mailbox: request has empty ID")
	}
	data, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshal request: %w", err)
	}
	dst := filepath.Join(m.Inbox(), req.ID+".req.json")
	return WriteAtomic(dst, data)
}

// ReadResponse reads outbox/<id>.res.json and best-effort deletes the file.
//
// Returns:
//   - (resp, true, nil)  — response was read and parsed successfully.
//   - (zero, false, nil) — file is not yet present.
//   - (zero, false, err) — IO or JSON-parse error.
//
// A failure to delete the file after a successful read is intentionally
// swallowed: the data has already been delivered to the caller, and the
// orphan response file will be reaped by the next SweepOutboxOlderThan
// (or by the hook's startup sweep). Surfacing the delete error to the
// caller would risk callers using `if err != nil { return }` and silently
// discarding valid data.
func (m *Mailbox) ReadResponse(id string) (proto.ExecResponse, bool, error) {
	path := filepath.Join(m.Outbox(), id+".res.json")
	// Use ReadFileRetry so a transient Windows ERROR_SHARING_VIOLATION
	// caused by the hook's WriteAtomic landing exactly when we open the
	// file doesn't fail the poll. Retry budget is ~14 ms.
	data, err := fileutil.ReadFileRetry(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return proto.ExecResponse{}, false, nil
		}
		return proto.ExecResponse{}, false, err
	}
	var resp proto.ExecResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		return proto.ExecResponse{}, false, fmt.Errorf("parse response %s: %w", path, err)
	}
	_ = os.Remove(path) // best-effort; orphan reaped by SweepOutboxOlderThan
	return resp, true, nil
}

// SweepOutboxOlderThan deletes *.res.json files in the outbox whose mtime
// is older than maxAge. Used to clean up orphans left by previous CLI runs
// that timed out before their response landed.
func (m *Mailbox) SweepOutboxOlderThan(maxAge time.Duration) error {
	return sweepDir(m.Outbox(), ".res.json", maxAge)
}

func sweepDir(dir, suffix string, maxAge time.Duration) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	}
	cutoff := time.Now().Add(-maxAge)
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if !strings.HasSuffix(e.Name(), suffix) && !strings.HasSuffix(e.Name(), ".tmp") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if info.ModTime().Before(cutoff) {
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
	return nil
}

// NewID returns a fresh UUID-based request ID.
func NewID() string {
	// google/uuid is small and stable; we keep its import inside this helper
	// to avoid leaking the dependency through the package's public surface.
	return uuidNew()
}
